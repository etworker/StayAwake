unit stayawake_common;

{$mode objfpc}{$H+}

interface

const
  APP_NAME = 'StayAwake';
  APP_VERSION = '0.2.0';
  INTERVAL_SECS = 60;
  ICON_SIZE = 32;

type
  TIconPixels = array[0 .. (ICON_SIZE * ICON_SIZE * 4) - 1] of Byte;

// Draw the tray/icon artwork into a caller-supplied RGBA buffer of
// Size x Size. Shared by the runtime trays (Size = ICON_SIZE, macOS uses 36)
// and tools/gen_icon.pas so the two can never drift apart.
//
// The artwork is an eye, matching the app's purpose of keeping the machine
// awake: open eye = actively preventing sleep, closed eye (with lashes) =
// paused so the system sleeps normally. Both states are single-color shapes
// on transparency, so macOS can also render them as a template image that
// adapts to the menu-bar appearance.
procedure GenerateIconPixels(Size: Integer; Active: Boolean; Pixels: PByte);

// Convenience wrapper for the fixed-size tray icon.
procedure GenerateTrayIconPixels(Active: Boolean; var Pixels: TIconPixels);

// Tiny one-value config store shared by the tray UI and background logic
// (language choice, lid-close mode). First line of the file is the value;
// any I/O problem leaves the default in place.
function ReadConfigValue(FileName, DefValue: string): string;
procedure WriteConfigValue(FileName, Value: string);

// == Shared tray core =========================================================
// One declarative menu tree + one set of user-visible strings serve all three
// platform trays. A platform tray (the "renderer") fills TrayConfigDir and the
// TrayHooks callbacks, then binds BuildTrayMenu's tree to its native widgets:
// every click funnels into MenuActionInvoke, every state sync reads
// MenuActionState, every label comes from L()/the node's Text.

type
  TTrayLang = (tlEn, tlZh);
  TStrMap = array[TTrayLang] of string;

  TMenuAction = (
    maNone,        // submenu titles / nodes without their own action
    maToggleAwake,
    maLidBlock,
    maLidAllow,
    maAutostart,
    maLangAuto,
    maLangEn,
    maLangZh,
    maAbout,
    maQuit
  );

  TMenuItemKind = (mkItem, mkCheck, mkRadio, mkSubmenu, mkSep);

  PMenuNode = ^TMenuNode;
  TMenuNode = record
    Kind: TMenuItemKind;
    Action: TMenuAction;
    Text: TStrMap;
    RadioGroup: Integer;             // mkRadio only; nodes sharing a group are exclusive
    Sub: array of PMenuNode;         // mkSubmenu only
  end;

  TTrayHooks = record
    HasLid: Boolean;                 // False on Windows (no lid feature)
    RefreshVisual: procedure; cdecl; // icon + tooltip + menu state re-sync
    ApplyAwake: procedure; cdecl;    // AppActive just changed: update assertions/nudge
    ApplyLidMode: procedure; cdecl;  // lid-mode file just changed: apply guard (Linux)
    ApplyLanguage: procedure; cdecl; // language file just changed: relabel everything
    ShowAbout: procedure; cdecl;
    Quit: procedure; cdecl;
    // External lid-state mechanism (macOS): when LidState is set, the menu's
    // lid radio reflects LidState() instead of the mode file, and lid clicks
    // are routed to LidRequest instead of writing the file.
    LidState: function: Boolean; cdecl;             // True = "block" effective
    LidRequest: procedure(ABlock: Boolean); cdecl;  // user picked a lid radio
  end;

var
  AppActive: Boolean;
  // Platform-provided before the tray starts (paths use the platform's own
  // config convention; language and lid-mode files share the stayawake/ dir).
  TrayConfigDir: string;
  TrayHooks: TTrayHooks;
  // Platform probe for the system UI language ('zh-Hans-CN', 'en-US', ...);
  // empty result or unset hook means "assume English". Needed because the
  // source of this information differs per platform (LANG env var, the
  // AppleLanguages default, GetUserDefaultUILanguage).
  TraySystemLang: function: string; cdecl;

// All user-visible strings, per language. Menu labels state the action and
// its consequence so each item is unambiguous. Single source for all trays.
const
  SAwake: TStrMap = ('Keep Awake (block idle sleep)', '保持清醒(阻止闲置睡眠)');
  SLidTitle: TStrMap = ('Lid Close on AC Power', '合盖行为(接电源时)');
  SLidBlock: TStrMap = ('Do Nothing (Guard blocks sleep)', '不动作(守卫拦截睡眠)');
  SLidAllow: TStrMap = ('Suspend (system default)', '睡眠(系统默认)');
  SAutoStart: TStrMap = ('Run at Login', '开机自启');
  SLangTitle: TStrMap = ('Language', '语言 / Language');
  SLangAuto: TStrMap = ('Follow System', '跟随系统');
  SAbout: TStrMap = ('About StayAwake', '关于 StayAwake');
  SQuit: TStrMap = ('Quit', '退出');
  STipWork: TStrMap = ('StayAwake - preventing sleep', 'StayAwake - 防睡中');
  STipPause: TStrMap = ('StayAwake - paused', 'StayAwake - 已暂停');
  SLangEn = 'English';
  SLangZh = '中文';

// Paths of the two per-user settings files (derived from TrayConfigDir).
function LangFilePath: string;
function LidFilePath: string;

// Language selection: explicit choice in the lang file wins, otherwise the
// system UI language (zh-* -> Chinese).
function CurrentLang: TTrayLang;
function CurrentLangStored: string;
function L(M: TStrMap): string;
procedure ApplyLanguage(ALang: string);

// Lid-close policy persistence ('block' / 'allow'; anything else = default).
function LidMode: string;
procedure SetLidMode(AMode: string);

// The one menu definition. Callers own the returned tree (FreeTrayMenu).
function BuildTrayMenu(HasLid: Boolean): PMenuNode;
procedure FreeTrayMenu(var Root: PMenuNode);

// Checked/radio state of an action, as the renderer should display it.
function MenuActionState(A: TMenuAction): Boolean;

// Central click dispatcher: applies the action and triggers the platform
// hooks. Unknown actions are ignored.
procedure MenuActionInvoke(A: TMenuAction);

// Localized tray tooltip for the current state.
function TrayTooltip: string;

// Bilingual About body (the dialog itself stays platform-native).
function AboutText: string;

implementation

uses
  SysUtils,
  Classes,
  stayawake_autostart;

procedure GenerateIconPixels(Size: Integer; Active: Boolean; Pixels: PByte);
const
  SS = 3; // supersampling grid per pixel axis (3x3 = 9 samples)
var
  x, y, sx, sy, idx, inside: Integer;
  u, v, dx, dy, yEdge, dIris, dist, shade: Double;
  cr, cg, cb: Double;
  cov: Double;
  // closed-eye geometry
  lx0, ly0, lx1, ly1, segLen, tSeg, dSeg, tLash: Double;
  lashX, signX: Double;
  li: Integer;
begin
  for y := 0 to Size - 1 do
  begin
    for x := 0 to Size - 1 do
    begin
      idx := (y * Size + x) * 4;
      inside := 0;
      cr := 0; cg := 0; cb := 0;
      for sy := 0 to SS - 1 do
      begin
        for sx := 0 to SS - 1 do
        begin
          u := (x + (sx + 0.5) / SS) / Size;
          v := (y + (sy + 0.5) / SS) / Size;
          dx := Abs(u - 0.5);
          dy := v - 0.5;
          cov := 0;
          if Active then
          begin
            // Open eye: almond outline (two arcs meeting at the corners)
            // plus a solid iris. 0.5 +- band around the lens boundary.
            if dx <= 0.40 then
            begin
              yEdge := 0.21 * Sqrt(1.0 - Sqr(dx / 0.40));
              if Abs(Abs(dy) - yEdge) <= 0.0275 then
                cov := 1
              // Iris disc, kept clear of the outline band.
              else if (Sqr(dx) + Sqr(dy) <= Sqr(0.135)) and
                      (Abs(dy) < yEdge - 0.0275) then
                cov := 1;
            end;
            if cov > 0 then
            begin
              dist := Sqrt(Sqr(dx) + Sqr(dy));
              shade := dist / 0.40;
              if shade > 1 then
                shade := 1;
              cr := cr + (110.0 - 70.0 * shade);
              cg := cg + (220.0 - 70.0 * shade);
              cb := cb + (150.0 - 60.0 * shade);
            end;
          end
          else
          begin
            // Closed eye: a downward-curving lid line plus three lashes.
            if dx <= 0.34 then
            begin
              yEdge := 0.03 + 0.135 * Sqrt(1.0 - Sqr(dx / 0.34));
              if Abs(dy - yEdge) <= 0.028 then
                cov := 1;
            end;
            // Lashes: thick line segments from the lid going down/outward.
            for li := -1 to 1 do
            begin
              lashX := li * 0.16;
              if lashX = 0 then
                signX := 0
              else
                signX := lashX / Abs(lashX);
                lx0 := 0.5 + lashX;
                ly0 := 0.5 + 0.03 + 0.135 * Sqrt(1.0 - Sqr(lashX / 0.34)) + 0.02;
                lx1 := lx0 + signX * 0.11 * 0.35;
                ly1 := ly0 + 0.11;
                segLen := Sqrt(Sqr(lx1 - lx0) + Sqr(ly1 - ly0));
                tSeg := ((u - lx0) * (lx1 - lx0) + (v - ly0) * (ly1 - ly0)) / Sqr(segLen);
                if tSeg < 0 then
                  tSeg := 0;
                if tSeg > 1 then
                  tSeg := 1;
                dSeg := Sqrt(Sqr(u - (lx0 + tSeg * (lx1 - lx0))) +
                             Sqr(v - (ly0 + tSeg * (ly1 - ly0))));
                tLash := 0.022;
                if dSeg <= tLash then
                  cov := 1;
            end;
            if cov > 0 then
            begin
              cr := cr + 160.0;
              cg := cg + 160.0;
              cb := cb + 160.0;
            end;
          end;
          if cov > 0 then
            Inc(inside);
        end;
      end;
      if inside > 0 then
      begin
        cov := inside / Sqr(SS);
        Pixels[idx] := Round(cr / inside);
        Pixels[idx + 1] := Round(cg / inside);
        Pixels[idx + 2] := Round(cb / inside);
        Pixels[idx + 3] := Round(255.0 * cov);
      end
      else
      begin
        Pixels[idx] := 0;
        Pixels[idx + 1] := 0;
        Pixels[idx + 2] := 0;
        Pixels[idx + 3] := 0;
      end;
    end;
  end;
end;

procedure GenerateTrayIconPixels(Active: Boolean; var Pixels: TIconPixels);
begin
  GenerateIconPixels(ICON_SIZE, Active, @Pixels[0]);
end;

// == Shared tray core =========================================================

const
  RG_LID = 1;
  RG_LANG = 2;
  SEmpty: TStrMap = ('', '');

function LangFilePath: string;
begin
  if TrayConfigDir = '' then
    Exit('');
  Result := TrayConfigDir + '/stayawake/lang';
end;

function LidFilePath: string;
begin
  if TrayConfigDir = '' then
    Exit('');
  Result := TrayConfigDir + '/stayawake/lid-mode';
end;

function CurrentLangStored: string;
begin
  Result := LowerCase(ReadConfigValue(LangFilePath, ''));
end;

function CurrentLang: TTrayLang;
var
  Stored, Sys: string;
begin
  Result := tlEn;
  Stored := CurrentLangStored;
  if Stored = 'zh' then
    Exit(tlZh);
  if Stored = 'en' then
    Exit(tlEn);
  // No explicit choice yet: follow the system UI language (zh-* -> Chinese).
  if Assigned(TraySystemLang) then
  begin
    Sys := LowerCase(TraySystemLang());
    if Pos('zh', Sys) = 1 then
      Result := tlZh;
  end;
end;

function L(M: TStrMap): string;
begin
  Result := M[CurrentLang];
end;

procedure ApplyLanguage(ALang: string);
begin
  if (ALang <> '') and (ALang <> 'en') and (ALang <> 'zh') then
    Exit;
  WriteConfigValue(LangFilePath, ALang);
  if Assigned(TrayHooks.ApplyLanguage) then
    TrayHooks.ApplyLanguage;
end;

function LidMode: string;
begin
  if ReadConfigValue(LidFilePath, 'allow') = 'block' then
    Result := 'block'
  else
    Result := 'allow';
end;

procedure SetLidMode(AMode: string);
begin
  if (AMode <> 'block') and (AMode <> 'allow') then
    Exit;
  WriteConfigValue(LidFilePath, AMode);
  if Assigned(TrayHooks.ApplyLidMode) then
    TrayHooks.ApplyLidMode;
end;

procedure AddChild(Parent: PMenuNode; Child: PMenuNode);
begin
  SetLength(Parent^.Sub, Length(Parent^.Sub) + 1);
  Parent^.Sub[High(Parent^.Sub)] := Child;
end;

function NewNode(AKind: TMenuItemKind; AAction: TMenuAction;
  const AText: TStrMap; ARadioGroup: Integer): PMenuNode;
begin
  New(Result);
  FillChar(Result^, SizeOf(TMenuNode), 0);
  Result^.Kind := AKind;
  Result^.Action := AAction;
  Result^.Text := AText;
  Result^.RadioGroup := ARadioGroup;
end;

procedure FreeNode(var N: PMenuNode);
var
  i: Integer;
begin
  if N = nil then
    Exit;
  for i := 0 to High(N^.Sub) do
    FreeNode(N^.Sub[i]);
  SetLength(N^.Sub, 0);
  Dispose(N);
  N := nil;
end;

function BuildTrayMenu(HasLid: Boolean): PMenuNode;
var
  lid, lang: PMenuNode;
  Fixed: TStrMap;
begin
  Result := NewNode(mkSubmenu, maNone, SEmpty, 0);   // invisible root

  AddChild(Result, NewNode(mkCheck, maToggleAwake, SAwake, 0));
  AddChild(Result, NewNode(mkSep, maNone, SEmpty, 0));

  if HasLid then
  begin
    lid := NewNode(mkSubmenu, maNone, SLidTitle, 0);
    AddChild(lid, NewNode(mkRadio, maLidBlock, SLidBlock, RG_LID));
    AddChild(lid, NewNode(mkRadio, maLidAllow, SLidAllow, RG_LID));
    AddChild(Result, lid);
  end;

  AddChild(Result, NewNode(mkCheck, maAutostart, SAutoStart, 0));
  AddChild(Result, NewNode(mkSep, maNone, SEmpty, 0));

  lang := NewNode(mkSubmenu, maNone, SLangTitle, 0);
  AddChild(lang, NewNode(mkRadio, maLangAuto, SLangAuto, RG_LANG));
  Fixed[tlEn] := SLangEn;  Fixed[tlZh] := SLangEn;
  AddChild(lang, NewNode(mkRadio, maLangEn, Fixed, RG_LANG));
  Fixed[tlEn] := SLangZh;  Fixed[tlZh] := SLangZh;
  AddChild(lang, NewNode(mkRadio, maLangZh, Fixed, RG_LANG));
  AddChild(Result, lang);

  AddChild(Result, NewNode(mkSep, maNone, SEmpty, 0));
  AddChild(Result, NewNode(mkItem, maAbout, SAbout, 0));
  AddChild(Result, NewNode(mkSep, maNone, SEmpty, 0));
  AddChild(Result, NewNode(mkItem, maQuit, SQuit, 0));
end;

procedure FreeTrayMenu(var Root: PMenuNode);
begin
  FreeNode(Root);
end;

function MenuActionState(A: TMenuAction): Boolean;
begin
  case A of
    maToggleAwake: Result := AppActive;
    maAutostart:   Result := IsAutoStartEnabled;
    maLidBlock:    if Assigned(TrayHooks.LidState) then
                     Result := TrayHooks.LidState()
                   else
                     Result := LidMode = 'block';
    maLidAllow:    if Assigned(TrayHooks.LidState) then
                     Result := not TrayHooks.LidState()
                   else
                     Result := LidMode <> 'block';
    maLangAuto:    Result := (CurrentLangStored <> 'en') and (CurrentLangStored <> 'zh');
    maLangEn:      Result := CurrentLangStored = 'en';
    maLangZh:      Result := CurrentLangStored = 'zh';
  else
    Result := False;
  end;
end;

procedure MenuActionInvoke(A: TMenuAction);
begin
  case A of
    maToggleAwake:
    begin
      AppActive := not AppActive;
      if Assigned(TrayHooks.ApplyAwake) then
        TrayHooks.ApplyAwake;
      if Assigned(TrayHooks.RefreshVisual) then
        TrayHooks.RefreshVisual;
    end;
    maAutostart:
    begin
      if IsAutoStartEnabled then
        DisableAutoStart
      else
        EnsureAutoStart;
      if Assigned(TrayHooks.RefreshVisual) then
        TrayHooks.RefreshVisual;
    end;
    maLidBlock:
      if Assigned(TrayHooks.LidRequest) then
        TrayHooks.LidRequest(True)
      else
        SetLidMode('block');
    maLidAllow:
      if Assigned(TrayHooks.LidRequest) then
        TrayHooks.LidRequest(False)
      else
        SetLidMode('allow');
    maLangAuto:  ApplyLanguage('');
    maLangEn:    ApplyLanguage('en');
    maLangZh:    ApplyLanguage('zh');
    maAbout:     if Assigned(TrayHooks.ShowAbout) then TrayHooks.ShowAbout;
    maQuit:      if Assigned(TrayHooks.Quit) then TrayHooks.Quit;
  end;
end;

function TrayTooltip: string;
begin
  if AppActive then
    Result := L(STipWork)
  else
    Result := L(STipPause);
end;

function AboutText: string;
begin
  Result :=
      APP_NAME + ' ' + APP_VERSION + #10#10 +
      'Prevents idle sleep by moving the mouse every ' +
      IntToStr(INTERVAL_SECS) + ' seconds.' + #10#10 +
      '防止系统因「闲置」而睡眠 / 熄屏 / 锁屏。';
end;

function ReadConfigValue(FileName, DefValue: string): string;
var
  sl: TStringList;
begin
  Result := DefValue;
  if (FileName = '') or (not FileExists(FileName)) then
    Exit;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(FileName);
      if sl.Count > 0 then
        Result := Trim(sl[0]);
    except
      on E: Exception do
        ;
    end;
  finally
    sl.Free;
  end;
end;

procedure WriteConfigValue(FileName, Value: string);
var
  sl: TStringList;
begin
  if FileName = '' then
    Exit;
  if not ForceDirectories(ExtractFilePath(FileName)) then
    Exit;
  sl := TStringList.Create;
  try
    sl.Add(Value);
    try
      sl.SaveToFile(FileName);
    except
      // Config must not crash the tray; the setting stays unchanged.
      on E: Exception do
        ;
    end;
  finally
    sl.Free;
  end;
end;

end.
