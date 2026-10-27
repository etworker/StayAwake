unit stayawake_mover;

{$mode objfpc}{$H+}

interface

uses
  stayawake_common;

procedure StartMoverThread;
procedure UpdateExecutionState;
procedure OnSystemSleep;
procedure OnSystemWake;
// Re-evaluates the per-power-source disablesleep policy (block mode:
// AC closed stays awake; battery closed stays awake for the configured
// minutes then sleeps). Called on every mover tick and on mode changes.
procedure LidPolicyApply;

implementation

uses
  Classes,
  SysUtils,
  DateUtils,
  dynlibs,
  ctypes,
  MacOSAll;

procedure PowerLog(const s: string);
var
  f: TextFile;
begin
  AssignFile(f, '/tmp/stayawake_power.log');
  if FileExists('/tmp/stayawake_power.log') then
    Append(f)
  else
    Rewrite(f);
  try
    WriteLn(f, FormatDateTime('hh:nn:ss.zzz', Now), ' [mover] ', s);
  finally
    CloseFile(f);
  end;
end;

type
  CGPoint = record
    x: Double;
    y: Double;
  end;
  CGEventRef = Pointer;
  CGEventType = cint;
  TCGEventCreate = function(source: Pointer): CGEventRef; cdecl;
  TCGEventGetLocation = function(ev: CGEventRef): CGPoint; cdecl;
  TCGEventCreateMouseEvent = function(source: Pointer; mouseType: CGEventType;
                                      p: CGPoint; button: cint): CGEventRef; cdecl;
  TCGEventPost = procedure(tap: cint; ev: CGEventRef); cdecl;
  TCFRelease = procedure(cf: Pointer); cdecl;
  TIOPMAssertionCreateWithName = function(AssertionType: CFStringRef;
    AssertionLevel: cint; Reason: CFStringRef; var AssertionID: cuint32): cint; cdecl;
  TIOPMAssertionRelease = function(AssertionID: cuint32): cint; cdecl;
  TIOServiceGetMatchingService = function(mainPort: Pointer;
    matching: Pointer): Pointer; cdecl;
  TIOServiceMatching = function(name: PAnsiChar): Pointer; cdecl;
  TIORegistryEntryCreateCFProperty = function(entry: Pointer; key: CFStringRef;
    allocator: Pointer; options: cuint32): Pointer; cdecl;
  TIOObjectRelease = function(obj: Pointer): cint; cdecl;
  TCGGetOnlineDisplayList = function(maxDisplays: cuint32; displays: PCUInt;
    var onlineCount: cuint32): cint; cdecl;
  TCGDisplayIsBuiltin = function(display: cuint32): Boolean; cdecl;

var
  CGHandle: TLibHandle;
  CGDisp: TLibHandle = NilHandle;
  CGEventCreate: TCGEventCreate;
  CGEventGetLocation: TCGEventGetLocation;
  CGEventCreateMouseEvent: TCGEventCreateMouseEvent;
  CGEventPost: TCGEventPost;
  CGFRelease: TCFRelease;

  // macOS power-management assertion (IOPMAssertion) loaded dynamically so the
  // binary keeps working even if IOKit symbols are unavailable; the mouse
  // nudge in NudgeMouse() is the standalone fallback that still prevents sleep.
  PMHandle: TLibHandle = NilHandle;
  IOPMAssertionCreateWithName: TIOPMAssertionCreateWithName = nil;
  IOPMAssertionRelease: TIOPMAssertionRelease = nil;
  gAssertionID: cuint32 = 0;
  gAssertionOn: Boolean = False;
  gSleepCoop: Boolean = False;   // released for an allowed system sleep; re-arm on wake
  // Lid policy state
  IOServiceGetMatchingService: TIOServiceGetMatchingService = nil;
  IOServiceMatching: TIOServiceMatching = nil;
  IORegistryEntryCreateCFProperty: TIORegistryEntryCreateCFProperty = nil;
  IOObjectRelease: TIOObjectRelease = nil;
  CGGetOnlineDisplayList: TCGGetOnlineDisplayList = nil;
  CGDisplayIsBuiltin: TCGDisplayIsBuiltin = nil;
  gLastAppliedC: Integer = -1;   // last disablesleep value applied per source
  gLastAppliedB: Integer = -1;
  gClosedSince: TDateTime = 0;
  gWasClosed: Boolean = False;
  gBatSleepSent: Boolean = False;

procedure InitCoreGraphics;
begin
  CGEventCreate := nil;
  CGEventGetLocation := nil;
  CGEventCreateMouseEvent := nil;
  CGEventPost := nil;
  CGFRelease := nil;

  CGHandle := LoadLibrary('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
  if CGHandle = NilHandle then
    CGHandle := LoadLibrary('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices');
  if CGHandle = NilHandle then
    Exit;
  CGEventCreate := TCGEventCreate(GetProcAddress(CGHandle, 'CGEventCreate'));
  CGEventGetLocation := TCGEventGetLocation(GetProcAddress(CGHandle, 'CGEventGetLocation'));
  CGEventCreateMouseEvent := TCGEventCreateMouseEvent(GetProcAddress(CGHandle, 'CGEventCreateMouseEvent'));
  CGEventPost := TCGEventPost(GetProcAddress(CGHandle, 'CGEventPost'));
  CGFRelease := TCFRelease(GetProcAddress(CGHandle, 'CFRelease'));
  CGGetOnlineDisplayList := TCGGetOnlineDisplayList(GetProcAddress(CGHandle, 'CGGetOnlineDisplayList'));
  CGDisplayIsBuiltin := TCGDisplayIsBuiltin(GetProcAddress(CGHandle, 'CGDisplayIsBuiltin'));
end;

procedure NudgeMouse;
const
  kCGEventMouseMoved = 5;
  kCGHIDEventTap = 0;
var
  cur, ev: CGEventRef;
  loc, loc2: CGPoint;
begin
  if (CGEventCreate = nil) or (CGEventGetLocation = nil) or
     (CGEventCreateMouseEvent = nil) or (CGEventPost = nil) then
    Exit;
  cur := CGEventCreate(nil);
  if cur = nil then
    Exit;
  loc := CGEventGetLocation(cur);
  if CGFRelease <> nil then
    CGFRelease(cur);

  loc2.x := loc.x + 1;
  loc2.y := loc.y;
  ev := CGEventCreateMouseEvent(nil, kCGEventMouseMoved, loc2, 0);
  if ev <> nil then
  begin
    CGEventPost(kCGHIDEventTap, ev);
    if CGFRelease <> nil then
      CGFRelease(ev);
  end;

  Sleep(50);

  ev := CGEventCreateMouseEvent(nil, kCGEventMouseMoved, loc, 0);
  if ev <> nil then
  begin
    CGEventPost(kCGHIDEventTap, ev);
    if CGFRelease <> nil then
      CGFRelease(ev);
  end;
end;

procedure InitPowerManagement;
begin
  if PMHandle <> NilHandle then
    Exit;
  PMHandle := LoadLibrary('/System/Library/Frameworks/IOKit.framework/IOKit');
  if PMHandle = NilHandle then
    Exit;
  IOPMAssertionCreateWithName := TIOPMAssertionCreateWithName(
    GetProcAddress(PMHandle, 'IOPMAssertionCreateWithName'));
  IOPMAssertionRelease := TIOPMAssertionRelease(
    GetProcAddress(PMHandle, 'IOPMAssertionRelease'));
end;

function popen(cmd: PAnsiChar; mode: PAnsiChar): Pointer; cdecl; external 'c' name 'popen';
function pclose(stream: Pointer): cint; cdecl; external 'c' name 'pclose';
function fgets(buf: PAnsiChar; size: cint; stream: Pointer): PAnsiChar; cdecl; external 'c' name 'fgets';
function system(cmd: PAnsiChar): cint; cdecl; external 'c' name 'system';

function PopenRead(const cmd: string): string;
const
  ReadBufSize = 512;
var
  f: Pointer;
  buf: array[0..ReadBufSize - 1] of AnsiChar;
  ln: PAnsiChar;
begin
  Result := '';
  f := popen(PAnsiChar(cmd), PAnsiChar('r'));
  if f = nil then
    Exit;
  try
    repeat
      ln := fgets(buf, ReadBufSize, f);
      if ln <> nil then
        Result := Result + string(ln);
    until ln = nil;
  finally
    pclose(f);
  end;
end;

procedure RunPmset(const args: string);
begin
  // Passwordless via the scoped sudoers entry installed by
  // src/macos/guard/install.sh; sudo -n fails silently when missing, in
  // which case the setting simply is not applied this round.
  PowerLog('pmset ' + args);
  system(PAnsiChar(AnsiString('/usr/bin/sudo -n /usr/bin/pmset ' + args + ' 2>/dev/null')));
end;

// True when running on AC power (parses `pmset -g batt`); fails open to
// False = treated as battery (conservative).
function OnACPower: Boolean;
var
  outp: string;
begin
  Result := False;
  outp := PopenRead('/usr/bin/pmset -g batt 2>/dev/null');
  Result := Pos('AC Power', outp) > 0;
end;

// Tell macOS we are actively presenting so idle sleep / display sleep is
// suppressed while AppActive. IOPMAssertions are process-global, so the
// tray thread can create/release them directly.
procedure UpdateExecutionState;
var
  reason, atype: CFStringRef;
  res: cint;
begin
  if AppActive then
  begin
    if gAssertionOn then
      Exit;
    if IOPMAssertionCreateWithName = nil then
      Exit;
    reason := CFStringCreateWithCString(nil, PAnsiChar('StayAwake keeps this Mac awake'),
      kCFStringEncodingUTF8);
    atype := CFStringCreateWithCString(nil, PAnsiChar('NoDisplaySleepAssertion'),
      kCFStringEncodingUTF8);
    res := -1;
    if (reason <> nil) and (atype <> nil) then
      res := IOPMAssertionCreateWithName(atype, 255, reason, gAssertionID);
    if reason <> nil then
      CFRelease(reason);
    if atype <> nil then
      CFRelease(atype);
    if res = 0 then
      gAssertionOn := True;
    PowerLog(Format('UpdateExecutionState: create res=%d', [res]));
  end
  else
  begin
    if not gAssertionOn then
      Exit;
    if (IOPMAssertionRelease <> nil) and (gAssertionID <> 0) then
      IOPMAssertionRelease(gAssertionID);
    gAssertionID := 0;
    gAssertionOn := False;
  end;
end;

// Cooperation with explicit system sleep (Apple menu / power button): the
// system does not need our permission, but dropping the display assertion
// keeps powerd's view clean; re-created on wake while still active.
procedure OnSystemSleep;
begin
  PowerLog(Format('OnSystemSleep: held=%s', [BoolToStr(gAssertionOn, True)]));
  if gAssertionOn and (IOPMAssertionRelease <> nil) and (gAssertionID <> 0) then
  begin
    IOPMAssertionRelease(gAssertionID);
    gAssertionID := 0;
    gAssertionOn := False;
    gSleepCoop := True;
  end;
end;

procedure OnSystemWake;
begin
  PowerLog(Format('OnSystemWake: coop=%s active=%s', [BoolToStr(gSleepCoop, True), BoolToStr(AppActive, True)]));
  if gSleepCoop then
  begin
    gSleepCoop := False;
    UpdateExecutionState;
    PowerLog('OnSystemWake: re-arm done');
  end;
end;

// ---- Lid policy (per power source) -------------------------------------------
// block mode: AC closed -> stay awake indefinitely; battery closed -> stay
// awake for LidBatteryMinutes then sleep (and stay asleep). Disablesleep is
// applied per source via the passwordless sudoers whitelist; the sleep at
// timer expiry is `pmset sleepnow` (global, but the machine is on battery
// at that point).
function BuiltinDisplayOnline: Boolean;
var
  ids: array[0..15] of cuint32;
  n, i: cuint32;
  builtin: Boolean;
begin
  // Built-in panel online = lid open; offline = closed. Under disablesleep
  // the system ignores the lid switch entirely (AppleClamshellState stays
  // false), so the panel power state is the observable lid signal.
  Result := True;   // uncertain -> treat as online (fail open)
  if (CGGetOnlineDisplayList = nil) or (CGDisplayIsBuiltin = nil) then
    Exit;
  n := 0;
  if CGGetOnlineDisplayList(Length(ids), @ids[0], n) <> 0 then
    Exit;
  builtin := False;
  for i := 0 to n - 1 do
    if CGDisplayIsBuiltin(ids[i]) then
    begin
      builtin := True;
      Break;
    end;
  Result := builtin;
end;

procedure LidPolicyApply;
var
  acAwake: Boolean;
  mins, elapsed: Integer;
  lidClosed, onAC: Boolean;
  wantC, wantB: Integer;
begin
  acAwake := LidAcAwake;
  mins := LidBatteryMinutes;
  lidClosed := not BuiltinDisplayOnline;
  if lidClosed and (not gWasClosed) then
  begin
    gClosedSince := Now;
    gBatSleepSent := False;
  end;
  if not lidClosed then
  begin
    gClosedSince := 0;
    gBatSleepSent := False;
  end;
  gWasClosed := lidClosed;
  onAC := OnACPower;

  // Per-tick diagnostic: shows exactly what the policy sees and decides.
  PowerLog(Format('tick: acAwake=%s mins=%d lidClosed=%s onAC=%s elapsed=%d sent=%s',
    [BoolToStr(acAwake, True), mins, BoolToStr(lidClosed, True),
     BoolToStr(onAC, True), elapsed, BoolToStr(gBatSleepSent, True)]));

  // Disablesleep profiles are armed persistently per source (so a later lid
  // close is covered without any race); the battery timer only decides when
  // to disarm the battery profile and send the sleep.
  wantC := Ord(acAwake);
  wantB := Ord((not gBatSleepSent) and (mins > 0));

  if acAwake and lidClosed and (not onAC) and (mins > 0) and (not gBatSleepSent) then
  begin
    if gClosedSince <> 0 then
      elapsed := MinutesBetween(Now, gClosedSince)
    else
      elapsed := 0;
    if elapsed >= mins then
    begin
      // Timer expired on battery: disarm and put the machine to sleep; it
      // stays asleep (the battery profile stays at disablesleep 0).
      gBatSleepSent := True;
      wantB := 0;
      RunPmset('-b disablesleep 0');
      RunPmset('sleepnow');
      PowerLog(Format('battery lid timer (%d min) expired: sleeping', [mins]));
    end;
  end;

  if (wantC <> gLastAppliedC) or (wantB <> gLastAppliedB) then
  begin
    RunPmset(Format('-c disablesleep %d', [wantC]));
    RunPmset(Format('-b disablesleep %d', [wantB]));
    gLastAppliedC := wantC;
    gLastAppliedB := wantB;
    PowerLog(Format('policy applied: ac=%d bat=%d (lidClosed=%s acPower=%s)',
      [wantC, wantB, BoolToStr(lidClosed, True), BoolToStr(onAC, True)]));
  end;
end;

type
  TMoverThread = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TMoverThread.Execute;
begin
  while not Terminated do
  begin
    Sleep(INTERVAL_SECS * 1000);
    if AppActive and (not Terminated) then
      NudgeMouse;
    if not Terminated then
      LidPolicyApply;
  end;
end;

procedure StartMoverThread;
begin
  InitCoreGraphics;
  InitPowerManagement;
  UpdateExecutionState;
  LidPolicyApply;
  with TMoverThread.Create(False) do
    FreeOnTerminate := True;
end;

initialization
  InitPowerManagement;

end.
