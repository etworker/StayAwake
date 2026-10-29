unit stayawake_common;

{$MODE objfpc}
{$H+}

interface

const
  APP_NAME = 'StayAwake';
  APP_VERSION = '0.2.0';
  INTERVAL_SECS = 60;
  ICON_SIZE = 32;

type
  TIconPixels = array[0..(ICON_SIZE * ICON_SIZE * 4) - 1] of Byte;

// Draw the tray/icon artwork into a caller-supplied RGBA buffer of
// Size x Size. Shared by the runtime trays (Size = ICON_SIZE, macOS uses 36)
// and tools/gen_icon.pas so the two can never drift apart.
//
// The artwork is an eye, matching the app's purpose of keeping the machine
// awake: open eye = actively preventing sleep, closed eye (with lashes) =
// paused so the system sleeps normally. Both states are single-color shapes
// on transparency, so they read equally well on dark and light surfaces.
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
  TLangPack = record
    Code: string; // filename stem: stayawake.<code>.lang
    Name: string; // 'name=' line: the language's own display name
  end;

const
  // How many language packs can be discovered. Generous on purpose; packs
  // beyond the cap are ignored (the shipped set is two).
  LANG_SLOTS = 6;

var
  // Discovered language packs, in filename order (see DiscoverLangPacks).
  LangPacks: array[1..LANG_SLOTS] of TLangPack;
  LangPackCount: Integer;

type
  TMenuAction = (
      maNone, // submenu titles / nodes without their own action
      maToggleAwake,
      maLidBlock,
      maLidAllow,
      maAutostart,
      maLangAuto,
      maLangPack1, // one slot per discovered language pack (see LANG_SLOTS)
      maLangPack2,
      maLangPack3,
      maLangPack4,
      maLangPack5,
      maLangPack6,
      maAbout,
      maQuit
  );

  TMenuItemKind = (mkItem, mkCheck, mkRadio, mkSubmenu, mkSep);

  PMenuNode = ^TMenuNode;
  TMenuNode = record
    Kind: TMenuItemKind;
    Action: TMenuAction;
    Text: string; // string-table key ('SAwake'), resolved via L()
    RadioGroup: Integer; // mkRadio only; nodes sharing a group are exclusive
    Sub: array of PMenuNode; // mkSubmenu only
  end;

  TTrayHooks = record
    HasLid: Boolean; // False on Windows (no lid feature)
    RefreshVisual: procedure; cdecl; // icon + tooltip + menu state re-sync
    ApplyAwake: procedure; cdecl; // AppActive just changed: update assertions/nudge
    ApplyLidMode: procedure; cdecl; // lid-mode file just changed: apply guard (Linux)
    ApplyLanguage: procedure; cdecl; // language file just changed: relabel everything
    ShowAbout: procedure; cdecl;
    Quit: procedure; cdecl;
    // External lid-state mechanism (macOS): when LidState is set, the menu's
    // lid radio reflects LidState() instead of the mode file, and lid clicks
    // are routed to LidRequest instead of writing the file.
    LidState: function: Boolean; cdecl; // True = "block" effective
    LidRequest: procedure(ABlock: Boolean); cdecl; // user picked a lid radio
    // Login-item state and apply, platform-native (registry Run key /
    // .desktop file / SMAppService). Behind hooks like every other platform
    // touchpoint, so this unit stays platform-independent and tools such as
    // gen_icon can link it without a platform unit.
    AutostartState: function: Boolean; cdecl; // True = enabled
    AutostartRequest: procedure(AEnable: Boolean); cdecl; // checkbox flipped
  end;

var
  AppActive: Boolean;
  // Platform-provided before the tray starts (paths use the platform's own
  // config convention; language and lid-mode files share the stayawake/ dir).
  TrayConfigDir: string;
  // Directory scanned for language packs (stayawake.<code>.lang). Platforms
  // set it to the install location: next to the executable on Windows/Linux,
  // <bundle>/Contents/Resources on macOS. Empty disables pack discovery.
  TrayLangPackDir: string;
  TrayHooks: TTrayHooks;
  // Platform probe for the system UI language ('zh-Hans-CN', 'en-US', ...);
  // empty result or unset hook means "assume English". Needed because the
  // source of this information differs per platform (LANG env var, the
  // AppleLanguages default, GetUserDefaultUILanguage).
  TraySystemLang: function: string; cdecl;

// Paths of the two per-user settings files (derived from TrayConfigDir).
function LangFilePath: string;
function LidFilePath: string;

// Language selection: the first line of the lang config file names a
// discovered pack ('en', 'zh', ...); empty or unmatched = follow the system
// UI language when that pack exists; otherwise the shipped English pack;
// otherwise the built-in English strings compiled into this unit. There is
// deliberately no menu UI for it — language is a set-once preference.
procedure DiscoverLangPacks;
function CurrentLangStored: string;
function L(const Key: string): string;
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

// Localized About body (the dialog itself stays platform-native).
function AboutText: string;

implementation

uses
  SysUtils,
  Classes;

procedure GenerateIconPixels(Size: Integer; Active: Boolean; Pixels: PByte);
const
  SS = 3; // supersampling grid per pixel axis (3x3 = 9 samples)
var
  x, y, sx, sy, idx, inside: Integer;
  u, v, dx, dy, yEdge, dist, shade: Double;
  cr, cg, cb: Double;
  cov: Double;
  // closed-eye geometry
  lx0, ly0, lx1, ly1, segLen, tSeg, dSeg, tLash: Double;
  lashX, signX: Double;
  li: Integer;
begin
  for y := 0 to Size - 1 do begin
    for x := 0 to Size - 1 do begin
      idx := (y * Size + x) * 4;
      inside := 0;
      cr := 0;
      cg := 0;
      cb := 0;
      for sy := 0 to SS - 1 do begin
        for sx := 0 to SS - 1 do begin
          u := (x + (sx + 0.5) / SS) / Size;
          v := (y + (sy + 0.5) / SS) / Size;
          dx := Abs(u - 0.5);
          dy := v - 0.5;
          cov := 0;
          if Active then begin
            // Open eye: almond outline (two arcs meeting at the corners)
            // plus a solid iris. 0.5 +- band around the lens boundary.
            if dx <= 0.46 then begin
              yEdge := 0.27 * Sqrt(1.0 - Sqr(dx / 0.46));
              if Abs(Abs(dy) - yEdge) <= 0.032 then
                cov :=
                    1
                        // Iris disc, kept clear of the outline band.
              else if (Sqr(dx) + Sqr(dy) <= Sqr(0.175)) and (Abs(dy) < yEdge - 0.032) then
                cov := 1;
            end;
            if cov > 0 then begin
              dist := Sqrt(Sqr(dx) + Sqr(dy));
              shade := dist / 0.46;
              if shade > 1 then
                shade := 1;
              cr := cr + (110.0 - 70.0 * shade);
              cg := cg + (220.0 - 70.0 * shade);
              cb := cb + (150.0 - 60.0 * shade);
            end;
          end
          else begin
            // Closed eye: a downward-curving lid line plus three lashes.
            if dx <= 0.43 then begin
              yEdge := 0.02 + 0.17 * Sqrt(1.0 - Sqr(dx / 0.43));
              if Abs(dy - yEdge) <= 0.032 then
                cov := 1;
            end;
            // Lashes: thick line segments from the lid going down/outward.
            for li := -1 to 1 do begin
              lashX := li * 0.20;
              if lashX = 0 then
                signX := 0
              else
                signX := lashX / Abs(lashX);
              lx0 := 0.5 + lashX;
              ly0 := 0.5 + 0.02 + 0.17 * Sqrt(1.0 - Sqr(lashX / 0.43)) + 0.02;
              lx1 := lx0 + signX * 0.11 * 0.39;
              ly1 := ly0 + 0.14;
              segLen := Sqrt(Sqr(lx1 - lx0) + Sqr(ly1 - ly0));
              tSeg := ((u - lx0) * (lx1 - lx0) + (v - ly0) * (ly1 - ly0)) / Sqr(segLen);
              if tSeg < 0 then
                tSeg := 0;
              if tSeg > 1 then
                tSeg := 1;
              dSeg := Sqrt(Sqr(u - (lx0 + tSeg * (lx1 - lx0))) + Sqr(v - (ly0 + tSeg * (ly1 - ly0))));
              tLash := 0.028;
              if dSeg <= tLash then
                cov := 1;
            end;
            if cov > 0 then begin
              cr := cr + 160.0;
              cg := cg + 160.0;
              cb := cb + 160.0;
            end;
          end;
          if cov > 0 then
            Inc(inside);
        end;
      end;
      if inside > 0 then begin
        cov := inside / Sqr(SS);
        Pixels[idx] := Round(cr / inside);
        Pixels[idx + 1] := Round(cg / inside);
        Pixels[idx + 2] := Round(cb / inside);
        Pixels[idx + 3] := Round(255.0 * cov);
      end
      else begin
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

  // Canonical string keys and the built-in English lines they resolve to.
  // Language packs override per key; a key missing from the active pack
  // falls back to the built-in English line, so a partial translation can
  // never blank out the UI.
  StrKeys: array[0..11] of string = (
      'SAwake',
      'SLidTitle',
      'SLidBlock',
      'SLidAllow',
      'SAutoStart',
      'SLangTitle',
      'SLangAuto',
      'SAbout',
      'SQuit',
      'STipWork',
      'STipPause',
      'SAboutDesc'
  );
  StrEn: array[0..11] of string = (
      'Keep Awake (block idle sleep)',
      'Lid Close on AC Power',
      'Do Nothing (Guard blocks sleep)',
      'Suspend (system default)',
      'Run at Login',
      'Language',
      'Follow System',
      'About StayAwake',
      'Quit',
      'StayAwake - preventing sleep',
      'StayAwake - paused',
      'Prevents idle sleep by moving the mouse every %d seconds.'
  );

var
  // The active language pack's key/value lines. Empty until the first
  // ActivateLanguage: L() then resolves everything from the built-in English
  // lines above.
  Cur: TStringList = nil;

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

function PackExists(const ACode: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 1 to LangPackCount do
    if LangPacks[i].Code = ACode then
      Exit(True);
end;

// Which discovered pack is in effect: an explicit choice naming a pack wins,
// else the system UI language (zh-* -> 'zh') when that pack exists, else the
// shipped English pack, else '' (= built-in English lines).
function ActivePackCode: string;
var
  Stored, Sys: string;
begin
  Result := '';
  Stored := CurrentLangStored;
  if (Stored <> '') and PackExists(Stored) then
    Exit(Stored);
  if Assigned(TraySystemLang) then begin
    Sys := LowerCase(TraySystemLang());
    if (Pos('zh', Sys) = 1) and PackExists('zh') then
      Exit('zh');
  end;
  if PackExists('en') then
    Exit('en');
  // Single custom-pack installs (e.g. a translator testing a fresh pack):
  // fall back to the first discovered pack instead of built-in English.
  if LangPackCount > 0 then
    Result := LangPacks[1].Code;
end;

// True if the bytes form well-formed UTF-8 (no BOM handling; overlong
// sequences accepted — this is content sniffing, not strict validation).
function ValidUtf8Bytes(P: PByte; Len: Integer): Boolean;
var
  n: Integer;
begin
  Result := True;
  while Len > 0 do begin
    if (P^ and $80) = 0 then
      n := 0
    else if (P^ and $E0) = $C0 then
      n := 1
    else if (P^ and $F0) = $E0 then
      n := 2
    else if (P^ and $F8) = $F0 then
      n := 3
    else
      Exit(False);
    Inc(P);
    Dec(Len);
    while n > 0 do begin
      if (Len = 0) or ((P^ and $C0) <> $80) then
        Exit(False);
      Inc(P);
      Dec(Len);
      Dec(n);
    end;
  end;
end;

// Read a language pack in whatever encoding a translator is likely to have
// saved: UTF-8 (with or without BOM) or the system ANSI code page (e.g.
// GB2312/GBK on Chinese Windows). The lines land in Dest as UTF-8 bytes,
// which is what UTF8Decode at the render sites expects.
procedure LoadPackLines(const FileName: string; Dest: TStringList);
var
  fs: TFileStream;
  Size: Integer;
  B: TBytes;
  Raw, S: RawByteString;
  IsUtf8: Boolean;
begin
  Dest.Clear;
  fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    Size := fs.Size;
    SetLength(B, Size);
    if Size > 0 then
      fs.ReadBuffer(B[0], Size);
  finally
    fs.Free;
  end;
  if Size = 0 then
    Exit;
  SetString(Raw, PAnsiChar(@B[0]), Size);
  if (Size >= 3) and (B[0] = $EF) and (B[1] = $BB) and (B[2] = $BF) then begin
    // UTF-8 BOM: strip it, the rest is already UTF-8.
    Raw := Copy(Raw, 4, Size - 3);
    IsUtf8 := True;
  end
  else
    IsUtf8 := ValidUtf8Bytes(@B[0], Size);
  if IsUtf8 then
    S := Raw
  else begin
    // Invalid UTF-8: assume the system ANSI code page and convert.
    S := AnsiToUtf8(Raw);
    SetCodePage(S, CP_ACP, False); // relabel only — the bytes are UTF-8 now
  end;
  Dest.Text := S;
end;

// Full path of an existing pack file for a code, checking the user's lang
// dir (TrayConfigDir/lang — survives app updates) before the app's own dir.
// '' when the code has no pack file anywhere.
function PackPath(const ACode: string): string;
begin
  Result := '';
  if (TrayConfigDir <> '') and FileExists(TrayConfigDir + '/stayawake/langs/stayawake.' + ACode + '.lang') then
    Exit(TrayConfigDir + '/stayawake/langs/stayawake.' + ACode + '.lang');
  if (TrayLangPackDir <> '') and FileExists(TrayLangPackDir + '/stayawake.' + ACode + '.lang') then
    Exit(TrayLangPackDir + '/stayawake.' + ACode + '.lang');
end;

procedure ActivateLanguage;
var
  Code, FName: string;
  i: Integer;
  sl: TStringList;
begin
  // Refresh Cur from the active pack. Keys missing from the pack simply stay
  // absent, and L() falls back to the built-in English lines.
  Cur.Clear;
  for i := 1 to LangPackCount do
    Cur.Add('PackName.' + LangPacks[i].Code + '=' + LangPacks[i].Name);
  Code := ActivePackCode;
  FName := PackPath(Code);
  if FName <> '' then begin
    sl := TStringList.Create;
    try
      LoadPackLines(FName, sl);
      Cur.AddStrings(sl);
    finally
      sl.Free;
    end;
  end;
end;

// Scan TrayLangPackDir for stayawake.<code>.lang files and (re)load the
// active strings. Runs before the menu tree is built, so adding a pack and
// restarting makes it appear in the language submenu automatically.
// Add every stayawake.<code>.lang in ADir whose code is not discovered yet.
// Scanning the user dir before the app dir lets a user pack override a
// shipped pack of the same code.
procedure AddPacksFromDir(const ADir: string);
var
  sr: TSearchRec;
  rc: Integer;
  Code, Name: string;
  sl: TStringList;
begin
  if (ADir = '') or (LangPackCount >= LANG_SLOTS) then
    Exit;
  rc := FindFirst(ADir + '/stayawake.*.lang', faAnyFile, sr);
  try
    while (rc = 0) and (LangPackCount < LANG_SLOTS) do begin
      if (sr.Attr and faDirectory) = 0 then begin
        Code := Copy(sr.Name, Length('stayawake.') + 1, Length(sr.Name) - Length('stayawake.') - Length('.lang'));
        if (Code <> '') and (not PackExists(Code)) then begin
          Name := Code;
          sl := TStringList.Create;
          try
            LoadPackLines(ADir + '/' + sr.Name, sl);
            if Trim(sl.Values['name']) <> '' then
              Name := Trim(sl.Values['name']);
          finally
            sl.Free;
          end;
          Inc(LangPackCount);
          LangPacks[LangPackCount].Code := Code;
          LangPacks[LangPackCount].Name := Name;
        end;
      end;
      rc := FindNext(sr);
    end;
  finally
    FindClose(sr);
  end;
end;

procedure DiscoverLangPacks;
var
  i: Integer;
begin
  LangPackCount := 0;
  for i := 1 to LANG_SLOTS do begin
    LangPacks[i].Code := '';
    LangPacks[i].Name := '';
  end;
  // User dir first (overrides), then the packs shipped with the app.
  if TrayConfigDir <> '' then
    AddPacksFromDir(TrayConfigDir + '/stayawake/langs');
  AddPacksFromDir(TrayLangPackDir);
  ActivateLanguage;
end;

// Resolve a string-table key to the active language's text, falling back to
// the built-in English line. Unknown keys return ''.
function L(const Key: string): string;
var
  i: Integer;
begin
  Result := '';
  if Cur <> nil then
    Result := Cur.Values[Key];
  if Result = '' then
    for i := 0 to High(StrKeys) do
      if StrKeys[i] = Key then
        Exit(StrEn[i]);
end;

procedure ApplyLanguage(ALang: string);
begin
  if (ALang <> '') and (not PackExists(ALang)) then
    Exit;
  WriteConfigValue(LangFilePath, ALang);
  ActivateLanguage;
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

function NewNode(AKind: TMenuItemKind; AAction: TMenuAction; const AText: string; ARadioGroup: Integer): PMenuNode;
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
const
  LangActions: array[1..LANG_SLOTS] of TMenuAction =
      (maLangPack1, maLangPack2, maLangPack3, maLangPack4, maLangPack5, maLangPack6);
var
  lid, lang: PMenuNode;
  i: Integer;
begin
  // Discover packs and load the active language strings before any label
  // resolves; by now the platform has set TrayLangPackDir.
  DiscoverLangPacks;
  Result := NewNode(mkSubmenu, maNone, '', 0); // invisible root

  AddChild(Result, NewNode(mkCheck, maToggleAwake, 'SAwake', 0));
  AddChild(Result, NewNode(mkSep, maNone, '', 0));

  if HasLid then begin
    lid := NewNode(mkSubmenu, maNone, 'SLidTitle', 0);
    AddChild(lid, NewNode(mkRadio, maLidBlock, 'SLidBlock', RG_LID));
    AddChild(lid, NewNode(mkRadio, maLidAllow, 'SLidAllow', RG_LID));
    AddChild(Result, lid);
  end;

  AddChild(Result, NewNode(mkCheck, maAutostart, 'SAutoStart', 0));
  AddChild(Result, NewNode(mkSep, maNone, '', 0));

  lang := NewNode(mkSubmenu, maNone, 'SLangTitle', 0);
  AddChild(lang, NewNode(mkRadio, maLangAuto, 'SLangAuto', RG_LANG));
  for i := 1 to LangPackCount do
    AddChild(lang, NewNode(mkRadio, LangActions[i], 'PackName.' + LangPacks[i].Code, RG_LANG));
  AddChild(Result, lang);

  AddChild(Result, NewNode(mkSep, maNone, '', 0));
  AddChild(Result, NewNode(mkItem, maAbout, 'SAbout', 0));
  AddChild(Result, NewNode(mkSep, maNone, '', 0));
  AddChild(Result, NewNode(mkItem, maQuit, 'SQuit', 0));
end;

procedure FreeTrayMenu(var Root: PMenuNode);
begin
  FreeNode(Root);
end;

function LangSlotMatches(Slot: Integer): Boolean;
begin
  Result := (Slot >= 1) and (Slot <= LangPackCount) and (CurrentLangStored = LangPacks[Slot].Code);
end;

function LangSlotCode(Slot: Integer): string;
begin
  Result := '';
  if (Slot >= 1) and (Slot <= LangPackCount) then
    Result := LangPacks[Slot].Code;
end;

function MenuActionState(A: TMenuAction): Boolean;
begin
  case A of
    maToggleAwake: Result := AppActive;
    maAutostart:
      if Assigned(TrayHooks.AutostartState) then
        Result := TrayHooks.AutostartState()
      else
        Result := False;
    maLidBlock:
      if Assigned(TrayHooks.LidState) then
        Result := TrayHooks.LidState()
      else
        Result := LidMode = 'block';
    maLidAllow:
      if Assigned(TrayHooks.LidState) then
        Result := not TrayHooks.LidState()
      else
        Result := LidMode <> 'block';
    maLangAuto: Result := (CurrentLangStored = '') or (not PackExists(CurrentLangStored));
    maLangPack1: Result := LangSlotMatches(1);
    maLangPack2: Result := LangSlotMatches(2);
    maLangPack3: Result := LangSlotMatches(3);
    maLangPack4: Result := LangSlotMatches(4);
    maLangPack5: Result := LangSlotMatches(5);
    maLangPack6: Result := LangSlotMatches(6);
  else
    Result := False;
  end;
end;

procedure MenuActionInvoke(A: TMenuAction);
var
  CurEnabled: Boolean;
begin
  case A of
    maToggleAwake: begin
      AppActive := not AppActive;
      if Assigned(TrayHooks.ApplyAwake) then
        TrayHooks.ApplyAwake;
      if Assigned(TrayHooks.RefreshVisual) then
        TrayHooks.RefreshVisual;
    end;
    maAutostart: begin
      if Assigned(TrayHooks.AutostartRequest) then begin
        CurEnabled := False;
        if Assigned(TrayHooks.AutostartState) then
          CurEnabled := TrayHooks.AutostartState();
        if CurEnabled then
          TrayHooks.AutostartRequest(False)
        else
          TrayHooks.AutostartRequest(True);
        if Assigned(TrayHooks.RefreshVisual) then
          TrayHooks.RefreshVisual;
      end;
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
    maLangAuto: ApplyLanguage('');
    maLangPack1: ApplyLanguage(LangSlotCode(1));
    maLangPack2: ApplyLanguage(LangSlotCode(2));
    maLangPack3: ApplyLanguage(LangSlotCode(3));
    maLangPack4: ApplyLanguage(LangSlotCode(4));
    maLangPack5: ApplyLanguage(LangSlotCode(5));
    maLangPack6: ApplyLanguage(LangSlotCode(6));
    maAbout:
      if Assigned(TrayHooks.ShowAbout) then
        TrayHooks.ShowAbout;
    maQuit:
      if Assigned(TrayHooks.Quit) then
        TrayHooks.Quit;
  end;
end;

function TrayTooltip: string;
begin
  if AppActive then
    Result := L('STipWork')
  else
    Result := L('STipPause');
end;

function AboutText: string;
begin
  Result := APP_NAME + ' ' + APP_VERSION + #10#10 + Format(L('SAboutDesc'), [INTERVAL_SECS]);
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

initialization
  // Until packs are discovered, L() resolves everything from the built-in
  // English lines — so even a missing/corrupt pack directory can't blank
  // out the UI.
  Cur := TStringList.Create;

finalization
  Cur.Free;
end.
