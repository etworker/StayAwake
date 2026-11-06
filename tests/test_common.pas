{$MODE objfpc}
{$H+}
program test_common;

{ Unit tests for the platform-independent tray core in stayawake_common.
  Runs on every platform (links the platform's stayawake_autostart/mover
  through the normal -Fu search paths, but never calls autostart itself so
  the host machine's login-item state is not disturbed).

  Deliberately dependency-free (hand-rolled checks instead of FPCUnit) so it
  compiles with nothing but the RTL. Exit code 0 = all pass. }

uses
  SysUtils,
  Classes,
  stayawake_common,
  stayawake_lidpolicy;

var
  FailCount: Integer = 0;
  CheckCount: Integer = 0;

procedure Check(const name: string; cond: Boolean);
begin
  Inc(CheckCount);
  if cond then
    WriteLn('PASS: ', name)
  else begin
    WriteLn('FAIL: ', name);
    Inc(FailCount);
  end;
end;

function TempConfigDir: string;
begin
  Result := GetTempDir + 'stayawake_unittest';
end;

// Partial packs on purpose: keys absent from a pack must fall back to the
// built-in English lines (this also proves discovery by filename).
procedure WriteLangPack(const Dir, Code, Name, SAwakeText, TipPauseText: string);
var
  D: string;
  sl: TStringList;
begin
  D := SetDirSeparators(Dir);
  ForceDirectories(D);
  sl := TStringList.Create;
  try
    sl.Add('name=' + Name);
    sl.Add('SAwake=' + SAwakeText);
    sl.Add('STipPause=' + TipPauseText);
    sl.SaveToFile(D + '/stayawake.' + Code + '.lang');
  finally
    sl.Free;
  end;
end;

// en < ja < zh alphabetically, so the discovery order (and thus the language
// radio slots) is deterministic on every platform.
procedure SetupLangPacks;
begin
  TrayLangPackDir := TempConfigDir;
  WriteLangPack(TrayLangPackDir, 'en', 'English', 'EN awake', 'EN paused');
  WriteLangPack(TrayLangPackDir, 'ja', '日本語', 'JA awake', 'JA paused');
  WriteLangPack(TrayLangPackDir, 'zh', '中文', '中文唤醒', '中文暂停');
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
  TrayHooks.AutostartState := nil;
  TrayHooks.AutostartRequest := nil;
  TraySystemLang := nil;
  ForceDirectories(TrayConfigDir + '/stayawake');
  DeleteFile(LangFilePath);
  DeleteFile(LidFilePath);
  SetupLangPacks;
  DiscoverLangPacks; // also re-activates the strings for the current choice
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
  WriteConfigValue('', 'x'); // must not raise
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
  Check(
      'C0 discovers 3 packs in filename order',
      (LangPackCount = 3) and (LangPacks[1].Code = 'en') and (LangPacks[2].Code = 'ja') and (LangPacks[3].Code = 'zh')
  );

  // Re-running discovery re-activates the strings: it stands in for a
  // relaunch wherever the test changes the inputs (stored choice, system
  // language) that language resolution reads.
  FakeLang := 'zh-Hans-CN';
  DiscoverLangPacks;
  Check('C1 no choice + zh system -> zh pack', L('STipPause') = '中文暂停');
  FakeLang := 'en-US';
  DiscoverLangPacks;
  Check('C2 no choice + en system -> en pack', L('STipPause') = 'EN paused');
  FakeLang := 'zh-Hans-CN';
  DiscoverLangPacks;
  ApplyLanguage('en');
  Check('C3 explicit en beats zh system', L('STipPause') = 'EN paused');
  ApplyLanguage('zh');
  Check('C4 explicit zh beats en system', L('STipPause') = '中文暂停');
  WriteConfigValue(LangFilePath, '  JUNK ');
  DiscoverLangPacks; // a hand-edited file is picked up like a relaunch
  Check('C5 junk falls back to system', (L('STipPause') = '中文暂停') and (CurrentLangStored = 'junk'));

  ApplyLanguage('xx');
  Check('C6 unknown ApplyLanguage rejected', CurrentLangStored <> 'xx');
  ApplyLanguage('');
  Check('C7 follow-system resets file to empty', CurrentLangStored = '');
  Check('C8 partial pack falls back to built-in English', (L('SAwake') = '中文唤醒') and (L('SQuit') = 'Quit'));
  Check('C9 pack-name keys resolve', L('PackName.ja') = '日本語');

  // A pack in the user's lang dir overrides a shipped pack of the same code.
  // The user dir is .../stayawake/langs (plural): 'lang' is the config file.
  ForceDirectories(TrayConfigDir + '/stayawake/langs');
  WriteLangPack(TrayConfigDir + '/stayawake/langs', 'zh', '中文(用户)', '中文(用户)', '中文暂停(用户)');
  DiscoverLangPacks;
  Check(
      'C10 user-dir pack overrides shipped',
      (LangPacks[1].Name = '中文(用户)') and (L('SAwake') = '中文(用户)')
  );
  DeleteFile(TrayConfigDir + '/stayawake/langs/stayawake.zh.lang');
  DiscoverLangPacks;
end;

// ---- D. menu tree -----------------------------------------------------------

function CountChildren(N: PMenuNode): Integer;
begin
  if N = nil then
    Result := -1
  else
    Result := Length(N^.Sub);
end;

// No two separators may ever be adjacent anywhere in the tree: renderers
// draw them as a double line. Recursive over submenus.
function NoConsecutiveSeps(Root: PMenuNode): Boolean;
var
  i: Integer;
  PrevSep: Boolean;
begin
  Result := True;
  PrevSep := False;
  for i := 0 to High(Root^.Sub) do begin
    if Root^.Sub[i]^.Kind = mkSep then begin
      if PrevSep then
        Exit(False);
      PrevSep := True;
    end
    else begin
      PrevSep := False;
      if (Root^.Sub[i]^.Kind = mkSubmenu) and (not NoConsecutiveSeps(Root^.Sub[i])) then
        Exit(False);
    end;
  end;
end;

procedure TestMenuTree;
var
  Root, Lid, Lang, Bat: PMenuNode;
  i: Integer;
begin
  ResetConfig;

  Root := BuildTrayMenu(True, False, False);
  Check('D1 lid tree (no sleepnow) has 10 top nodes', CountChildren(Root) = 10);
  Check('D2 first is checkable awake row', (Root^.Sub[0]^.Kind = mkCheck) and (Root^.Sub[0]^.Action = maToggleAwake));
  Lid := Root^.Sub[2];
  Check('D3 lid submenu title key', Lid^.Text = 'SLidTitle');
  Check(
      'D4 lid radios in one group',
      (Lid^.Sub[0]^.RadioGroup = Lid^.Sub[1]^.RadioGroup) and (Lid^.Sub[0]^.RadioGroup <> 0)
  );
  Check('D5 lid radio actions', (Lid^.Sub[0]^.Action = maLidBlock) and (Lid^.Sub[1]^.Action = maLidAllow));
  Lang := Root^.Sub[5];
  Check(
      'D6 lang submenu = follow-system + one radio per pack',
      (Lang^.Kind = mkSubmenu)
          and (CountChildren(Lang) = 1 + LangPackCount)
          and (Lang^.Sub[0]^.Action = maLangAuto)
          and (Lang^.Sub[1]^.Text = 'PackName.en')
  );
  Check('D7 separators present', (Root^.Sub[1]^.Kind = mkSep) and (Root^.Sub[4]^.Kind = mkSep));
  Check('D8 quit is last', Root^.Sub[9]^.Action = maQuit);
  Check('D8b lid tree has no double separators', NoConsecutiveSeps(Root));
  FreeTrayMenu(Root);

  Root := BuildTrayMenu(False, False, False);
  Check('D9 no-lid tree (no sleepnow) has 9 top nodes', CountChildren(Root) = 9);
  Check('D10 no lid submenu anywhere', (Root^.Sub[2]^.Action = maAutostart) and (Root^.Sub[2]^.Kind = mkCheck));
  FreeTrayMenu(Root);
  FreeTrayMenu(Root); // double free must be safe (nil check)
  Check('D11 double free safe', Root = nil);

  // macOS-style tree: lid off, Sleep Now on (item + its separator appended)
  Root := BuildTrayMenu(False, True, False);
  Check('D12 sleepnow tree has 11 top nodes', CountChildren(Root) = 11);
  Check(
      'D13 sleepnow item before the About group, single separator',
      (Root^.Sub[5]^.Kind = mkSep)
          and (Root^.Sub[6]^.Kind = mkItem)
          and (Root^.Sub[6]^.Action = maSleepNow)
          and (Root^.Sub[7]^.Kind = mkSep)
          and (Root^.Sub[8]^.Action = maAbout)
  );
  Check('D14 sleepnow label key', Root^.Sub[6]^.Text = 'SSleepNow');
  Check('D14b sleepnow tree has no double separators', NoConsecutiveSeps(Root));
  FreeTrayMenu(Root);

  // macOS per-source tree: flat sections - AC checkbox + battery radios
  Root := BuildTrayMenu(True, True, True);
  Check('D12b full mac tree has 12 top nodes', CountChildren(Root) = 12);
  Check('D12b2 mac tree has no double separators', NoConsecutiveSeps(Root));
  Lid := Root^.Sub[2];
  Check('D12c lid submenu is flat with 18 children', CountChildren(Lid) = 18);
  Check(
      'D12d ac header + checkbox',
      (Lid^.Sub[0]^.Kind = mkHeader)
          and (Lid^.Sub[0]^.Action = maNone)
          and (Lid^.Sub[1]^.Kind = mkCheck)
          and (Lid^.Sub[1]^.Action = maAcLidAwake)
  );
  Check(
      'D12e bat header + 7 radios (close, 1, 5, ..., 60, never)',
      (Lid^.Sub[3]^.Kind = mkHeader)
          and (Lid^.Sub[4]^.Kind = mkRadio)
          and (Lid^.Sub[4]^.Action = maBatClose)
          and (Lid^.Sub[5]^.Action = maBat1)
          and (Lid^.Sub[9]^.Action = maBat60)
          and (Lid^.Sub[10]^.Action = maBatNever)
          and (Lid^.Sub[4]^.RadioGroup = Lid^.Sub[10]^.RadioGroup)
  );
  Check(
      'D12f battery label keys resolve',
      (Lid^.Sub[4]^.Text = 'SBatClose')
          and (L('SBatClose') = 'Sleep on close (default)')
          and (Lid^.Sub[5]^.Text = 'SBat1')
          and (L('SBat1') = 'Stay awake 1 min, then sleep')
          and (Lid^.Sub[9]^.Text = 'SBat60')
          and (L('SBat60') = 'Stay awake 60 min, then sleep')
          and (Lid^.Sub[10]^.Text = 'SBatNever')
          and (L('SBatNever') = 'Stay awake until battery dies')
  );
  Check(
      'D12g pct header + 5 radios (off, 10, 15, 20, 25)',
      (Lid^.Sub[11]^.Kind = mkSep)
          and (Lid^.Sub[12]^.Kind = mkHeader)
          and (Lid^.Sub[12]^.Text = 'SLidPctHeader')
          and (Lid^.Sub[13]^.Kind = mkRadio)
          and (Lid^.Sub[13]^.Action = maPctOff)
          and (Lid^.Sub[13]^.Text = 'SPctOff')
          and (L('SPctOff') = 'Disabled')
          and (Lid^.Sub[14]^.Action = maPct10)
          and (Lid^.Sub[15]^.Action = maPct15)
          and (Lid^.Sub[16]^.Action = maPct20)
          and (Lid^.Sub[17]^.Action = maPct25)
          and (Lid^.Sub[13]^.RadioGroup = Lid^.Sub[17]^.RadioGroup)
          and (Lid^.Sub[13]^.RadioGroup <> Lid^.Sub[4]^.RadioGroup)
  );
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
  ACPath: string;
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

  // language dispatch writes the file (no ApplyLanguage hook needed).
  // Slots are in filename order: 1 = en, 2 = ja, 3 = zh.
  MenuActionInvoke(maLangPack3);
  Check('E5 lang zh persisted', CurrentLangStored = 'zh');
  Check(
      'E6 zh radio state',
      MenuActionState(maLangPack3) and not MenuActionState(maLangPack1) and not MenuActionState(maLangAuto)
  );
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
  WriteLn(
      'DEBUG E15: file=[',
      ReadConfigValue(LidBatteryMinutesPath, 'X'),
      '] mins=',
      LidBatteryMinutes,
      ' st30=',
      MenuActionState(maBat30),
      ' st15=',
      MenuActionState(maBat15)
  );
  Check(
      'E15 bat radio state 30',
      MenuActionState(maBat30)
          and not MenuActionState(maBat15)
          and not MenuActionState(maBat60)
          and not MenuActionState(maBat5)
  );
  MenuActionInvoke(maBat60);
  Check('E16 bat 60 persisted', Trim(ReadConfigValue(LidBatteryMinutesPath, '')) = '60');
  MenuActionInvoke(maBatClose);
  Check(
      'E16b bat close = 0 minutes, radio on',
      (LidBatteryMinutes = 0) and MenuActionState(maBatClose) and not MenuActionState(maBat60)
  );
  MenuActionInvoke(maBatNever);
  Check(
      'E16c bat never = -1, radio on',
      (LidBatteryMinutes = -1) and MenuActionState(maBatNever) and not MenuActionState(maBatClose)
  );
  WriteConfigValue(LidBatteryMinutesPath, 'junk');
  Check('E17 junk minutes falls back to 0', LidBatteryMinutes = 0);
  WriteConfigValue(LidBatteryPctPath, '20');
  Check('E18 pct floor parse', LidBatteryPct = 20);
  WriteConfigValue(LidBatteryPctPath, 'junk');
  Check('E18b pct floor junk defaults to 15', LidBatteryPct = 15);
  WriteConfigValue(LidBatteryPctPath, '0');
  Check('E18c pct floor 0 = off', LidBatteryPct = 0);
  WriteConfigValue(LidBatteryPctPath, '150');
  Check('E18d pct floor out of range defaults to 15', LidBatteryPct = 15);
  MenuActionInvoke(maPct20);
  Check(
      'E18e pct 20 persisted + radio on',
      (LidBatteryPct = 20) and MenuActionState(maPct20) and not MenuActionState(maPct15)
  );
  MenuActionInvoke(maPctOff);
  Check('E18f pct off persisted', (LidBatteryPct = 0) and MenuActionState(maPctOff) and not MenuActionState(maPct20));

  // AC lid checkbox (per-source style): file-based, toggle via dispatch.
  // Missing file defaults to awake (product decision).
  ACPath := TrayConfigDir + '/stayawake/lid-ac';
  DeleteFile(ACPath);
  Check('E18 ac awake defaults on (no file)', LidAcAwake and MenuActionState(maAcLidAwake));
  MenuActionInvoke(maAcLidAwake);
  Check('E19 toggled off', (not LidAcAwake) and not MenuActionState(maAcLidAwake));
  MenuActionInvoke(maAcLidAwake);
  Check('E20 toggled back on', LidAcAwake and MenuActionState(maAcLidAwake));
end;

// ---- G. lid policy decision core (stayawake_lidpolicy) ----------------------

procedure TestLidPolicy;
var
  d: TLidDecision;

  procedure Decide(AcAwake, LidClosed, OnAC: Boolean; Mins, Elapsed, Pct, Floor: Integer; Sent: Boolean;
    KernelHandlesClose: Boolean = True);
  begin
    d := LidDecide(AcAwake, LidClosed, OnAC, Mins, Elapsed, Pct, Floor, Sent, KernelHandlesClose);
  end;

begin
  // AC awake mode, lid open: both profiles armed, no sleep.
  Decide(True, False, True, 15, 0, 80, 15, False);
  Check(
      'G1 ac awake lid open arms both',
      (d.WantC = 1) and (d.WantB = 1) and (not d.SleepNow) and (d.Reason = ldrNone)
  );
  // Battery, closed, a second before expiry: still holding awake.
  Decide(True, True, False, 15, 899, 40, 15, False);
  Check('G2 battery closed before expiry keeps awake', (d.WantB = 1) and (not d.SleepNow) and (d.Reason = ldrNone));
  // Timer expires exactly at Mins*60 seconds.
  Decide(True, True, False, 15, 900, 40, 15, False);
  Check('G3 timer fires at exactly 900 s', d.SleepNow and (d.WantB = 0) and d.Sent and (d.Reason = ldrTimer));
  // Floor fires long before the timer would.
  Decide(True, True, False, 15, 120, 15, 15, False);
  Check('G4 floor fires at charge floor', d.SleepNow and (d.WantB = 0) and (d.Reason = ldrLowBattery));
  // Both conditions true on the same tick: floor wins (branch order).
  Decide(True, True, False, 15, 900, 10, 15, False);
  Check('G5 floor wins over timer same tick', d.SleepNow and (d.Reason = ldrLowBattery) and d.Sent);
  // Never-sleep mode (-1): timer can never fire, floor still bounds it.
  Decide(True, True, False, -1, 100000, 90, 15, False);
  Check('G6 never mode holds awake without floor hit', (d.WantB = 1) and (not d.SleepNow));
  Decide(True, True, False, -1, 100000, 15, 15, False);
  Check('G7 never mode floor is the safety net', d.SleepNow and (d.Reason = ldrLowBattery));
  // Sleep-on-close mode (0): floor still applies.
  Decide(True, True, False, 0, 60, 20, 20, False);
  Check('G8 mins=0 floor still fires', d.SleepNow and (d.WantB = 0) and (d.Reason = ldrLowBattery));
  // Unknown charge (-1): floor never fires, timer unaffected.
  Decide(True, True, False, 15, 900, -1, 15, False);
  Check('G9 unknown charge timer still fires', d.SleepNow and (d.Reason = ldrTimer));
  Decide(True, True, False, 15, 60, -1, 15, False);
  Check('G10 unknown charge no floor', (not d.SleepNow) and (d.WantB = 1));
  // Floor disabled (0): timer governs alone even at 5%.
  Decide(True, True, False, 15, 60, 5, 0, False);
  Check('G11 floor off ignores low charge', (not d.SleepNow) and (d.WantB = 1));
  // Mode off: nothing armed, nothing fires.
  Decide(False, True, False, 15, 900, 10, 15, False);
  Check('G12 mode off no sleep no arm', (d.WantC = 0) and (d.WantB = 0) and (not d.SleepNow));
  // Lid open: armed but the timer never fires while open.
  Decide(True, False, False, 15, 9000, 5, 15, False);
  Check('G13 lid open timer never fires', (d.WantB = 1) and (not d.SleepNow));
  // On AC: the battery conditions never fire.
  Decide(True, True, True, 15, 9000, 5, 15, False);
  Check('G14 on AC battery sleep never fires', (d.WantC = 1) and (d.WantB = 1) and (not d.SleepNow));
  // One-shot: sent=True suppresses everything, profile stays disarmed.
  Decide(True, True, False, 15, 900, 5, 15, True);
  Check('G15 sent=True no re-fire', (not d.SleepNow) and (d.WantB = 0) and d.Sent and (d.Reason = ldrNone));

  // KernelHandlesClose=False (Windows semantics, LidDecide 10th arg):
  // closes that should end in sleep must be executed by the app itself.
  Decide(False, True, True, 15, 60, 80, 15, False, False);
  Check('G21 win ac close checkbox off sleeps', d.SleepNow and d.Sent and (d.Reason = ldrClose));
  Decide(True, True, True, 15, 60, 80, 15, False, False);
  Check('G22 win ac close checkbox on holds', (not d.SleepNow) and (d.Reason = ldrNone));
  Decide(True, True, False, 0, 60, 80, 15, False, False);
  Check('G23 win battery mins=0 sleeps', d.SleepNow and (d.Reason = ldrClose));
  // Floor still wins over the immediate close on the same tick.
  Decide(True, True, False, 0, 60, 10, 15, False, False);
  Check('G24 win mins=0 floor wins same tick', d.SleepNow and (d.Reason = ldrLowBattery));
  // Windows battery timer runs even with the checkbox off (G12 counterpart).
  Decide(False, True, False, 15, 900, 80, 15, False, False);
  Check('G25 win timer runs with checkbox off', d.SleepNow and (d.Reason = ldrTimer));
  Decide(False, True, False, -1, 90000, 80, 15, False, False);
  Check('G26 win never mode holds', (not d.SleepNow));
  // macOS/Linux (True, default): checkbox off keeps the whole policy off.
  Decide(False, True, False, 0, 900, 80, 15, False, True);
  Check('G27 mac mins=0 checkbox off no sleep', (not d.SleepNow) and (d.Reason = ldrNone));

  // ParseChargePct against real pmset -g batt shapes.
  Check(
      'G16 battery line pct',
      ParseChargePct(
              'Now drawing from ''Battery Power'''#10
                  + ' -InternalBattery-0 (id=29818979)'#9'72%; charging; (no estimate) present: true')
          = 72
  );
  Check(
      'G17 ac line 100%',
      ParseChargePct(
              'Now drawing from ''AC Power'''#10 + ' -InternalBattery-0 (id=29818979)'#9'100%; charged; present: true')
          = 100
  );
  Check('G18 single digit pct', ParseChargePct('7%; discharging') = 7);
  Check('G19 no percent -> -1', ParseChargePct('nothing here') = -1);
  Check('G20 bare percent -> -1', ParseChargePct('%; foo') = -1);
end;

// ---- H. lid engine state machine (stayawake_lidpolicy) ----------------------

procedure TestLidEngine;
var
  S: TLidEngineState;
  d: TLidDecision;

  procedure Tick(Known, Closed, OnAC, AcAwake: Boolean; Mins, Pct, Floor: Integer; NowMs: Int64;
    Kernel: Boolean);
  begin
    d := LidEngineTick(S, Known, Closed, OnAC, AcAwake, Mins, Pct, Floor, Kernel, NowMs);
  end;

begin
  // Open: enforcement computed, episode state clean.
  LidEngineReset(S);
  Tick(True, False, True, True, 15, 80, 15, 1000, True);
  Check(
      'H1 open tick arms and resets',
      (d.WantC = 1) and (d.WantB = 1) and (not d.SleepNow) and (not S.WasClosed) and (S.ClosedSinceMs = 0)
  );
  // Close edge starts the clock; a second before expiry holds.
  Tick(True, True, False, True, 1, 80, 15, 5000, True);
  Check(
      'H2 close edge starts clock',
      S.WasClosed and (S.ClosedSinceMs = 5000) and (not d.SleepNow) and (d.WantB = 1)
  );
  Tick(True, True, False, True, 1, 80, 15, 59000, True);
  Check('H3 timer holds at 54 s', (not d.SleepNow));
  // Expiry: 1 min option fires 60 s after the close was first seen.
  Tick(True, True, False, True, 1, 80, 15, 65000, True);
  Check('H4 timer fires at 60 s', d.SleepNow and (d.Reason = ldrTimer) and d.Sent and (S.Sent = True));
  // One-shot: staying closed never re-fires.
  Tick(True, True, False, True, 1, 80, 15, 100000, True);
  Check('H5 no re-fire while closed', (not d.SleepNow) and (d.Reason = ldrNone));
  // Reopen resets the one-shot; the next close starts a fresh episode.
  Tick(True, False, False, True, 1, 80, 15, 110000, True);
  Check('H6 reopen resets episode', (not S.WasClosed) and (not S.Sent));
  Tick(True, True, False, True, 1, 80, 15, 112000, True);
  Check(
      'H7 fresh episode re-arms',
      (not d.SleepNow) and (S.ClosedSinceMs = 112000) and (not S.Sent)
  );
  // Unknown lid (no probe): never fires, never tracks an episode.
  LidEngineReset(S);
  Tick(False, False, False, True, 1, 80, 15, 1000, True);
  Check('H8 unknown lid no fire', (not d.SleepNow) and (not S.WasClosed));
  Tick(False, True, False, True, 1, 80, 15, 200000, True);
  Check('H9 unknown lid closed still no fire', (not d.SleepNow) and (not S.WasClosed));
  // Clock went backwards mid-episode: hold instead of firing early.
  LidEngineReset(S);
  Tick(True, True, False, True, 1, 80, 15, 10000, True);
  Tick(True, True, False, True, 1, 80, 15, 5000, True);
  Check('H10 backwards clock holds', (not d.SleepNow));
  // Windows mode (KernelHandlesClose=False): battery mins=0 sleeps on the
  // close tick itself, once per episode.
  LidEngineReset(S);
  Tick(True, True, False, True, 0, 80, 15, 1000, False);
  Check('H11 win mins=0 fires on close tick', d.SleepNow and (d.Reason = ldrClose) and S.Sent);
  Tick(True, True, False, True, 0, 80, 15, 60000, False);
  Check('H12 win one-shot holds', (not d.SleepNow));
  Tick(True, False, False, True, 0, 80, 15, 70000, False);
  Check('H13 win reopen re-arms', (not S.Sent));
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
  for si := 0 to High(Sizes) do begin
    Size := Sizes[si];
    SetLength(Pixels, Size * Size * 4);
    GenerateIconPixels(Size, True, @Pixels[0]);
    Check(
        'F1 active corners transparent (' + IntToStr(Size) + ')',
        (Pixels[3] = 0) and (Pixels[(Size - 1) * Size * 4 + 3] = 0)
    );
    opaque := 0;
    greenish := 0;
    for y := 0 to Size - 1 do
      for x := 0 to Size - 1 do begin
        idx := (y * Size + x) * 4;
        if Pixels[idx + 3] > 200 then begin
          Inc(opaque);
          if (Pixels[idx + 1] > Pixels[idx]) and (Pixels[idx + 1] > Pixels[idx + 2]) then
            Inc(greenish);
        end;
      end;
    Check('F2 active eye has opaque green pixels (' + IntToStr(Size) + ')', (opaque > 0) and (greenish > 0));

    GenerateIconPixels(Size, False, @Pixels[0]);
    grayish := 0;
    for i := 0 to Size * Size - 1 do begin
      idx := i * 4;
      if (Pixels[idx + 3] > 200) and (Pixels[idx] = Pixels[idx + 1]) and (Pixels[idx + 1] = Pixels[idx + 2]) then
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
  TestLidPolicy;
  TestLidEngine;
  WriteLn(Format('== %d checks, %d failures ==', [CheckCount, FailCount]));
  if FailCount > 0 then
    ExitCode := 1;
end.
