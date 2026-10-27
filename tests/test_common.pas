{$mode objfpc}{$H+}
program test_common;

{ Unit tests for the platform-independent tray core in stayawake_common.
  Runs on every platform (links the platform's stayawake_autostart/mover
  through the normal -Fu search paths, but never calls autostart itself so
  the host machine's login-item state is not disturbed).

  Deliberately dependency-free (hand-rolled checks instead of FPCUnit) so it
  compiles with nothing but the RTL. Exit code 0 = all pass. }

uses
  SysUtils, Classes, stayawake_common;

var
  FailCount: Integer = 0;
  CheckCount: Integer = 0;

procedure Check(const name: string; cond: Boolean);
begin
  Inc(CheckCount);
  if cond then
    WriteLn('PASS: ', name)
  else
  begin
    WriteLn('FAIL: ', name);
    Inc(FailCount);
  end;
end;

function TempConfigDir: string;
begin
  Result := GetTempDir + 'stayawake_unittest';
end;

procedure ResetConfig;
begin
  TrayConfigDir := TempConfigDir;
  TrayHooks.HasLid := True;
  TrayHooks.RefreshVisual := nil;
  TrayHooks.ApplyAwake := nil;
  TrayHooks.ApplyLidMode := nil;
  TrayHooks.ApplyLanguage := nil;
  TrayHooks.ShowAbout := nil;
  TrayHooks.Quit := nil;
  TrayHooks.LidState := nil;
  TrayHooks.LidRequest := nil;
  TraySystemLang := nil;
  ForceDirectories(TrayConfigDir + '/stayawake');
  DeleteFile(LangFilePath);
  DeleteFile(LidFilePath);
end;

// ---- A. config store --------------------------------------------------------

procedure TestConfigIO;
var
  Path: string;
begin
  ResetConfig;
  Path := TrayConfigDir + '/stayawake/unit';
  WriteConfigValue(Path, 'hello');
  Check('A1 write/read roundtrip', ReadConfigValue(Path, '') = 'hello');
  Check('A2 read adds no padding', ReadConfigValue(Path, '') = Trim(' hello'#10));
  Check('A3 missing file returns default', ReadConfigValue(Path + '.none', 'dflt') = 'dflt');
  Check('A4 empty name safe', ReadConfigValue('', 'dflt') = 'dflt');
  WriteConfigValue('', 'x');   // must not raise
  Check('A5 empty name write safe', True);
end;

// ---- B. path derivation -----------------------------------------------------

procedure TestPaths;
begin
  ResetConfig;
  Check('B1 lang path', LangFilePath = TrayConfigDir + '/stayawake/lang');
  Check('B2 lid path', LidFilePath = TrayConfigDir + '/stayawake/lid-mode');
  TrayConfigDir := '';
  Check('B3 empty dir -> empty paths', (LangFilePath = '') and (LidFilePath = ''));
end;

// ---- C. language ------------------------------------------------------------

var
  FakeLang: string;

function FakeSystemLang: string; cdecl;
begin
  Result := FakeLang;
end;

procedure TestLanguage;
begin
  ResetConfig;
  TraySystemLang := @FakeSystemLang;

  FakeLang := 'zh-Hans-CN';
  Check('C1 no choice + zh system -> zh', CurrentLang = tlZh);
  FakeLang := 'en-US';
  Check('C2 no choice + en system -> en', CurrentLang = tlEn);
  FakeLang := 'zh-Hans-CN';
  WriteConfigValue(LangFilePath, 'en');
  Check('C3 explicit en beats zh system', CurrentLang = tlEn);
  WriteConfigValue(LangFilePath, 'zh');
  Check('C4 explicit zh beats en system', CurrentLang = tlZh);
  WriteConfigValue(LangFilePath, '  JUNK ');
  Check('C5 junk falls back to system', (CurrentLang = tlZh) and (CurrentLangStored = 'junk'));

  ApplyLanguage('xx');
  Check('C6 invalid ApplyLanguage rejected', CurrentLangStored <> 'xx');
  ApplyLanguage('');
  Check('C7 follow-system resets file to empty', CurrentLangStored = '');
  Check('C8 L() maps by language', L(SQuit) = SQuit[CurrentLang]);
end;

// ---- D. menu tree -----------------------------------------------------------

function CountChildren(N: PMenuNode): Integer;
begin
  if N = nil then
    Result := -1
  else
    Result := Length(N^.Sub);
end;

procedure TestMenuTree;
var
  Root, Lid, Lang, Bat: PMenuNode;
  i: Integer;
begin
  ResetConfig;

  Root := BuildTrayMenu(True, False, False);
  Check('D1 lid tree (no sleepnow) has 10 top nodes', CountChildren(Root) = 10);
  Check('D2 first is checkable awake row',
    (Root^.Sub[0]^.Kind = mkCheck) and (Root^.Sub[0]^.Action = maToggleAwake));
  Lid := Root^.Sub[2];
  Check('D3 lid submenu title', (Lid^.Text[tlEn] = SLidTitle[tlEn]) and
    (Lid^.Text[tlZh] = SLidTitle[tlZh]));
  Check('D4 lid radios in one group',
    (Lid^.Sub[0]^.RadioGroup = Lid^.Sub[1]^.RadioGroup) and (Lid^.Sub[0]^.RadioGroup <> 0));
  Check('D5 lid radio actions', (Lid^.Sub[0]^.Action = maLidBlock) and
    (Lid^.Sub[1]^.Action = maLidAllow));
  Lang := Root^.Sub[5];
  Check('D6 lang submenu has 3 radios', (Lang^.Kind = mkSubmenu) and (CountChildren(Lang) = 3));
  Check('D7 separators present', (Root^.Sub[1]^.Kind = mkSep) and (Root^.Sub[4]^.Kind = mkSep));
  Check('D8 quit is last', Root^.Sub[9]^.Action = maQuit);
  FreeTrayMenu(Root);

  Root := BuildTrayMenu(False, False, False);
  Check('D9 no-lid tree (no sleepnow) has 9 top nodes', CountChildren(Root) = 9);
  Check('D10 no lid submenu anywhere',
    (Root^.Sub[2]^.Action = maAutostart) and (Root^.Sub[2]^.Kind = mkCheck));
  FreeTrayMenu(Root);
  FreeTrayMenu(Root);   // double free must be safe (nil check)
  Check('D11 double free safe', Root = nil);

  // macOS-style tree: lid off, Sleep Now on (item + its separator appended)
  Root := BuildTrayMenu(False, True, False);
  Check('D12 sleepnow tree has 11 top nodes', CountChildren(Root) = 11);
  Check('D13 sleepnow item placed before the About group',
    (Root^.Sub[5]^.Kind = mkItem) and (Root^.Sub[5]^.Action = maSleepNow) and
    (Root^.Sub[6]^.Kind = mkSep) and (Root^.Sub[8]^.Action = maAbout));
  Check('D14 sleepnow label', (Root^.Sub[5]^.Text[tlEn] = SSleepNow[tlEn]) and
    (Root^.Sub[5]^.Text[tlZh] = SSleepNow[tlZh]));
  FreeTrayMenu(Root);

  // macOS-style tree with the lid battery timer group
  Root := BuildTrayMenu(True, True, True);
  Check('D12b full mac tree has 12 top nodes', CountChildren(Root) = 12);
  Lid := Root^.Sub[2];
  Check('D12c lid submenu has block/allow/sep/bat = 4 children', CountChildren(Lid) = 4);
  Bat := Lid^.Sub[3];
  Check('D12d battery submenu is a group of 4 radios',
    (Bat^.Kind = mkSubmenu) and (CountChildren(Bat) = 4) and
    (Bat^.Sub[0]^.Action = maBat5) and (Bat^.Sub[3]^.Action = maBat60) and
    (Bat^.Sub[0]^.RadioGroup = Bat^.Sub[3]^.RadioGroup));
  Check('D12e battery labels localized',
    (Bat^.Sub[0]^.Text[tlZh] = '5 分钟后睡眠') and (Bat^.Sub[3]^.Text[tlEn] = '60 min, then sleep'));
  FreeTrayMenu(Root);
end;

// ---- E. states & dispatch ---------------------------------------------------

var
  HookCalls: Integer = 0;
  LastLidRequest: Integer = -2;

procedure StubRefreshVisual; cdecl;
begin
  Inc(HookCalls);
end;

procedure StubLidRequest(ABlock: Boolean); cdecl;
begin
  if ABlock then
    LastLidRequest := 1
  else
    LastLidRequest := 0;
  Inc(HookCalls);
end;

procedure TestStatesAndDispatch;
var
  CallsBefore: Integer;
begin
  ResetConfig;
  TrayHooks.RefreshVisual := @StubRefreshVisual;

  AppActive := False;
  Check('E1 awake state reflects AppActive', not MenuActionState(maToggleAwake));
  MenuActionInvoke(maToggleAwake);
  Check('E2 invoke toggles AppActive', AppActive);
  Check('E3 invoke triggered RefreshVisual', HookCalls > 0);
  MenuActionInvoke(maToggleAwake);
  Check('E4 toggle is symmetric', not AppActive);

  // language dispatch writes the file (no ApplyLanguage hook needed)
  MenuActionInvoke(maLangZh);
  Check('E5 lang zh persisted', CurrentLangStored = 'zh');
  Check('E6 zh radio state', MenuActionState(maLangZh) and
    not MenuActionState(maLangEn) and not MenuActionState(maLangAuto));
  MenuActionInvoke(maLangAuto);
  Check('E7 lang auto persisted', CurrentLangStored = '');
  Check('E8 auto radio state', MenuActionState(maLangAuto));

  // lid, file-based (no LidRequest hook): dispatcher writes the mode file
  TrayHooks.ApplyLidMode := nil;
  MenuActionInvoke(maLidBlock);
  Check('E9 file lid block', (LidMode = 'block') and MenuActionState(maLidBlock));
  MenuActionInvoke(maLidAllow);
  Check('E10 file lid allow', (LidMode = 'allow') and MenuActionState(maLidAllow));

  // lid, external mechanism (LidRequest hook): dispatcher must NOT touch the
  // file and must forward the request
  TrayHooks.LidState := nil;
  TrayHooks.LidRequest := @StubLidRequest;
  CallsBefore := HookCalls;
  MenuActionInvoke(maLidBlock);
  Check('E11 external lid request forwarded', LastLidRequest = 1);
  Check('E12 external mode leaves file alone', LidMode = 'allow');
  Check('E13 external hook invoked', HookCalls = CallsBefore + 1);
  TrayHooks.LidRequest := nil;

  // no hooks at all: about/quit must be no-ops, not crashes
  TrayHooks.ShowAbout := nil;
  TrayHooks.Quit := nil;
  MenuActionInvoke(maAbout);
  MenuActionInvoke(maQuit);
  Check('E14 nil-hook about/quit safe', True);

  // battery timer minutes: dispatch persists, state reads back
  WriteConfigValue(LidBatteryMinutesPath, '30');
  WriteLn('DEBUG E15: file=[', ReadConfigValue(LidBatteryMinutesPath, 'X'), '] mins=', LidBatteryMinutes,
    ' st30=', MenuActionState(maBat30), ' st15=', MenuActionState(maBat15));
  Check('E15 bat radio state 30', MenuActionState(maBat30) and
    not MenuActionState(maBat15) and not MenuActionState(maBat60) and not MenuActionState(maBat5));
  MenuActionInvoke(maBat60);
  Check('E16 bat 60 persisted', Trim(ReadConfigValue(LidBatteryMinutesPath, '')) = '60');
  WriteConfigValue(LidBatteryMinutesPath, 'junk');
  Check('E17 junk minutes falls back to 15', LidBatteryMinutes = 15);
end;

// ---- F. icon pixels ---------------------------------------------------------

procedure TestIconPixels;
const
  Sizes: array[0..3] of Integer = (16, 32, 36, 256);
var
  Size, si, x, y, idx, i, opaque, greenish, grayish: Integer;
  Pixels: array of Byte;
  Tray: TIconPixels;
begin
  ResetConfig;
  for si := 0 to High(Sizes) do
  begin
    Size := Sizes[si];
    SetLength(Pixels, Size * Size * 4);
    GenerateIconPixels(Size, True, @Pixels[0]);
    Check('F1 active corners transparent (' + IntToStr(Size) + ')',
      (Pixels[3] = 0) and (Pixels[(Size - 1) * Size * 4 + 3] = 0));
    opaque := 0; greenish := 0;
    for y := 0 to Size - 1 do
      for x := 0 to Size - 1 do
      begin
        idx := (y * Size + x) * 4;
        if Pixels[idx + 3] > 200 then
        begin
          Inc(opaque);
          if (Pixels[idx + 1] > Pixels[idx]) and (Pixels[idx + 1] > Pixels[idx + 2]) then
            Inc(greenish);
        end;
      end;
    Check('F2 active eye has opaque green pixels (' + IntToStr(Size) + ')',
      (opaque > 0) and (greenish > 0));

    GenerateIconPixels(Size, False, @Pixels[0]);
    grayish := 0;
    for i := 0 to Size * Size - 1 do
    begin
      idx := i * 4;
      if (Pixels[idx + 3] > 200) and (Pixels[idx] = Pixels[idx + 1]) and
         (Pixels[idx + 1] = Pixels[idx + 2]) then
        Inc(grayish);
    end;
    Check('F3 paused eye is gray (' + IntToStr(Size) + ')', grayish > 0);
  end;

  // tray wrapper must equal the generic renderer at ICON_SIZE
  SetLength(Pixels, ICON_SIZE * ICON_SIZE * 4);
  GenerateIconPixels(ICON_SIZE, True, @Pixels[0]);
  GenerateTrayIconPixels(True, Tray);
  idx := 0;
  for i := 0 to Length(Tray) - 1 do
    if Pixels[i] <> Tray[i] then
      Inc(idx);
  Check('F4 wrapper matches renderer byte-for-byte', idx = 0);
end;

begin
  WriteLn('== stayawake_common unit tests ==');
  TestConfigIO;
  TestPaths;
  TestLanguage;
  TestMenuTree;
  TestStatesAndDispatch;
  TestIconPixels;
  WriteLn(Format('== %d checks, %d failures ==', [CheckCount, FailCount]));
  if FailCount > 0 then
    ExitCode := 1;
end.
