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
  gClamSince: TDateTime = 0;
  gWasClam: Boolean = False;
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

// powerd's own clamshell flag from the IOPMrootDomain registry - the
// authoritative lid state, updated before any sleep request.
function AppleClamshellClosed: Boolean;
var
  svc, prop: Pointer;
  key: CFStringRef;
begin
  Result := False;
  if (IOServiceGetMatchingService = nil) or (IOServiceMatching = nil) or
     (IORegistryEntryCreateCFProperty = nil) or (IOObjectRelease = nil) then
    Exit;
  svc := IOServiceGetMatchingService(nil, IOServiceMatching('IOPMrootDomain'));
  if svc = nil then
    Exit;
  key := CFStringCreateWithCString(nil, PAnsiChar('AppleClamshellState'),
    kCFStringEncodingUTF8);
  prop := IORegistryEntryCreateCFProperty(svc, key, nil, 0);
  if prop <> nil then
  begin
    Result := prop = CFTypeRef(kCFBooleanTrue);
    CFRelease(prop);
  end;
  CFRelease(key);
  IOObjectRelease(svc);
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
procedure LidPolicyApply;
var
  mode: string;
  mins, elapsed: Integer;
  clam, onAC: Boolean;
  wantC, wantB: Integer;
begin
  if (IOServiceGetMatchingService = nil) or (CGGetOnlineDisplayList = nil) then
    Exit;
  mode := LidMode;
  mins := LidBatteryMinutes;
  clam := AppleClamshellClosed;
  if clam and (not gWasClam) then
  begin
    gClamSince := Now;
    gBatSleepSent := False;
  end;
  if not clam then
  begin
    gClamSince := 0;
    gBatSleepSent := False;
  end;
  gWasClam := clam;
  onAC := OnACPower;

  wantC := 0;
  wantB := 0;
  if mode = 'block' then
  begin
    wantC := 1;
    wantB := 1;
    if clam and (not onAC) then
    begin
      if gClamSince <> 0 then
        elapsed := MinutesBetween(Now, gClamSince)
      else
        elapsed := 0;
      if elapsed >= mins then
      begin
        // Timer expired: allow sleep on battery and put it to sleep now.
        wantB := 0;
        if not gBatSleepSent then
        begin
          RunPmset('-b disablesleep 0');
          RunPmset('sleepnow');
          gBatSleepSent := True;
          PowerLog('battery lid timer expired: sleeping now');
        end;
      end;
    end;
  end;

  if wantC <> gLastAppliedC then
  begin
    RunPmset(Format('-c disablesleep %d', [wantC]));
    gLastAppliedC := wantC;
  end;
  if wantB <> gLastAppliedB then
  begin
    RunPmset(Format('-b disablesleep %d', [wantB]));
    gLastAppliedB := wantB;
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
