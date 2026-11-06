unit stayawake_mover;

{$mode objfpc}{$H+}

interface

uses
  stayawake_common;

procedure StartMoverThread;
procedure UpdateExecutionState;
// Put the machine to sleep (unprivileged `systemctl suspend`). Shared by
// the lid policy engine and the tray's Sleep Now menu item.
procedure SystemSuspend;

implementation

uses
  Classes,
  SysUtils,
  dynlibs,
  ctypes,
  stayawake_lidpolicy;

// Lid policy glue for the shared engine (stayawake_lidpolicy): probing is
// plain file reads (/proc, /sys), enforcement is the guard script's job (it
// re-reads the same config files every cycle), and the only action here is
// `systemctl suspend`, which is unprivileged on systemd desktops. The tick
// runs unconditionally - the lid policy applies even when the keep-awake
// feature is paused (same as the macOS mover).

procedure UpdateExecutionState;
begin
  // Linux has no system-wide sleep-prevention API; the mouse nudge in
  // TMoverThread.Execute is the sole mechanism.  This stub exists so the
  // main program can call it uniformly across all platforms.
end;

procedure PowerLog(const s: string);
var
  f: TextFile;
begin
  try
    AssignFile(f, '/tmp/stayawake_power.log');
    if FileExists('/tmp/stayawake_power.log') then
      Append(f)
    else
      Rewrite(f);
    try
      WriteLn(f, FormatDateTime('hh:nn:ss.zzz', Now), ' [linux-mover] ', s);
    finally
      CloseFile(f);
    end;
  except
    // logging must never take the app down
  end;
end;

// First line of a one-value sysfs/procfs file; '' when unreadable.
function ReadFirstLine(const Path: string): string;
var
  f: TextFile;
  s: string;
begin
  Result := '';
  AssignFile(f, Path);
  {$I-}
  Reset(f);
  {$I+}
  if IOResult <> 0 then
    Exit;
  try
    ReadLn(f, s);
    Result := s;
  finally
    CloseFile(f);
  end;
end;

// Lid state from the ACPI button device. Known=False when the machine has
// no lid node (desktops): the engine then treats the lid as permanently
// open and no sleep decision ever fires. FPC's FindFirst does not expand
// wildcards in the middle of a path, so glob the lid DEVICE directory (e.g.
// LID0) and read <dir>/state below it.
procedure ProbeLid(out Known, Closed: Boolean);
var
  sr: TSearchRec;
  rc: Integer;
  s: string;
begin
  Known := False;
  Closed := False;
  rc := FindFirst('/proc/acpi/button/lid/*', faAnyFile, sr);
  if rc <> 0 then
    Exit;
  try
    while rc = 0 do begin
      if (sr.Attr and faDirectory) <> 0 then begin
        s := LowerCase(ReadFirstLine('/proc/acpi/button/lid/' + sr.Name + '/state'));
        if s <> '' then begin
          Known := True;
          Closed := Pos('closed', s) > 0;
          Exit;
        end;
      end;
      rc := FindNext(sr);
    end;
  finally
    FindClose(sr);
  end;
end;

// Kernel AC-adapter state, same source the guard script greps (immune to
// UPower misdetection). Any A* adapter reporting 1 counts.
function ProbeAC: Boolean;
var
  sr: TSearchRec;
  rc: Integer;
begin
  Result := False;
  rc := FindFirst('/sys/class/power_supply/A*', faAnyFile, sr);
  try
    while rc = 0 do begin
      if (sr.Attr and faDirectory) <> 0 then
        if Trim(ReadFirstLine('/sys/class/power_supply/' + sr.Name + '/online')) = '1' then
          Exit(True);
      rc := FindNext(sr);
    end;
  finally
    FindClose(sr);
  end;
end;

// First battery's charge percentage; -1 = unknown (the floor never fires).
function ProbeChargePct: Integer;
var
  sr: TSearchRec;
  rc: Integer;
  v: Integer;
begin
  Result := -1;
  rc := FindFirst('/sys/class/power_supply/BAT*', faAnyFile, sr);
  try
    while rc = 0 do begin
      if (sr.Attr and faDirectory) <> 0 then
        if TryStrToInt(Trim(ReadFirstLine('/sys/class/power_supply/' + sr.Name + '/capacity')), v)
            and (v >= 0) and (v <= 100) then
          Exit(v);
      rc := FindNext(sr);
    end;
  finally
    FindClose(sr);
  end;
end;

// Unprivileged on systemd: logind takes the request from the user session.
// libc system(), same style as the macOS mover's pmset calls.
procedure system(cmd: PAnsiChar); cdecl; external 'c' name 'system';

procedure SystemSuspend;
begin
  PowerLog('systemctl suspend');
  system(PAnsiChar('/usr/bin/systemctl suspend 2>/dev/null || /bin/systemctl suspend 2>/dev/null'));
end;

var
  gEngine: TLidEngineState;
  gProbeLogged: Boolean = False; // one-shot diagnostic line on the first tick

procedure LidPolicyTick;
var
  lidKnown, lidClosed, onAC, prevClosed: Boolean;
  pct: Integer;
  nowMs: Int64;
  dec: TLidDecision;
begin
  prevClosed := gEngine.WasClosed;
  ProbeLid(lidKnown, lidClosed);
  onAC := ProbeAC;
  pct := ProbeChargePct;
  if not gProbeLogged then begin
    gProbeLogged := True;
    // Would have made the "probes silently never match" class of bug
    // visible immediately (it did: this line caught a broken glob).
    PowerLog(Format('probe: lidKnown=%s lidClosed=%s onAC=%s pct=%d',
        [BoolToStr(lidKnown, True), BoolToStr(lidClosed, True), BoolToStr(onAC, True), pct]));
  end;
  nowMs := GetTickCount64;
  dec := LidEngineTick(
      gEngine, lidKnown, lidClosed, onAC, LidAcAwake,
      LidBatteryMinutes, pct, LidBatteryPct, True, nowMs);
  if lidKnown and (gEngine.WasClosed <> prevClosed) then begin
    if gEngine.WasClosed then
      PowerLog('lid closed')
    else
      PowerLog('lid open');
  end;
  if dec.SleepNow then begin
    case dec.Reason of
      ldrLowBattery: PowerLog(Format('battery low (%d%% <= %d%% floor): sleeping', [pct, LidBatteryPct]));
      ldrTimer: PowerLog(Format('battery lid timer (%d min) expired: sleeping', [LidBatteryMinutes]));
      ldrClose: PowerLog('close should sleep: suspending');
    end;
    SystemSuspend;
  end;
end;

type
  PDisplay = Pointer;
  TWindow = culong;
  PWindow = ^TWindow;
  TXOpenDisplay = function(name: PChar): PDisplay; cdecl;
  TXDefaultRootWindow = function(dpy: PDisplay): TWindow; cdecl;
  TXQueryPointer = function(dpy: PDisplay; w: TWindow; root, child: PWindow;
                            rx, ry, wx, wy: Pcint; mask: Pcuint): cint; cdecl;
  TXFlush = function(dpy: PDisplay): cint; cdecl;
  TXTestFakeMotionEvent = function(dpy: PDisplay; screen: cint; x, y: cint;
                                   delay: culong): cint; cdecl;

var
  XLib, XtstLib: TLibHandle;
  XOpenDisplay: TXOpenDisplay;
  XDefaultRootWindow: TXDefaultRootWindow;
  XQueryPointer: TXQueryPointer;
  XFlush: TXFlush;
  XTestFakeMotionEvent: TXTestFakeMotionEvent;
  XDpy: PDisplay;

procedure InitXtst;
begin
  XOpenDisplay := nil;
  XDefaultRootWindow := nil;
  XQueryPointer := nil;
  XFlush := nil;
  XTestFakeMotionEvent := nil;
  XDpy := nil;

  XLib := LoadLibrary('libX11.so.6');
  if XLib <> NilHandle then
  begin
    XOpenDisplay := TXOpenDisplay(GetProcAddress(XLib, 'XOpenDisplay'));
    XDefaultRootWindow := TXDefaultRootWindow(GetProcAddress(XLib, 'XDefaultRootWindow'));
    XQueryPointer := TXQueryPointer(GetProcAddress(XLib, 'XQueryPointer'));
    XFlush := TXFlush(GetProcAddress(XLib, 'XFlush'));
  end;

  XtstLib := LoadLibrary('libXtst.so.6');
  if XtstLib <> NilHandle then
    XTestFakeMotionEvent := TXTestFakeMotionEvent(GetProcAddress(XtstLib, 'XTestFakeMotionEvent'));

  if XOpenDisplay <> nil then
    XDpy := XOpenDisplay(nil);
end;

procedure NudgeMouse;
var
  root, child: TWindow;
  rootX, rootY, winX, winY: cint;
  mask: cuint;
begin
  if (XTestFakeMotionEvent = nil) or (XDpy = nil) or (XQueryPointer = nil) or
     (XDefaultRootWindow = nil) or (XFlush = nil) then
    Exit;
  root := XDefaultRootWindow(XDpy);
  child := 0;
  if XQueryPointer(XDpy, root, @root, @child, @rootX, @rootY, @winX, @winY, @mask) <> 0 then
  begin
    XTestFakeMotionEvent(XDpy, -1, rootX + 1, rootY, 0);
    XFlush(XDpy);
    Sleep(50);
    XTestFakeMotionEvent(XDpy, -1, rootX, rootY, 0);
    XFlush(XDpy);
  end;
end;

type
  TMoverThread = class(TThread)
  protected
    procedure Execute; override;
  end;

const
  LID_TICK_MS = 2000; // lid policy granularity: probes are plain file reads
  NUDGE_EVERY = INTERVAL_SECS * 1000 div LID_TICK_MS; // keep the 60 s nudge

procedure TMoverThread.Execute;
var
  Ticks: Integer;
begin
  Ticks := 0;
  LidEngineReset(gEngine);
  PowerLog('mover started');
  while not Terminated do
  begin
    Sleep(LID_TICK_MS);
    if Terminated then
      Break;
    LidPolicyTick;
    if AppActive then
    begin
      Inc(Ticks);
      if Ticks >= NUDGE_EVERY then
      begin
        Ticks := 0;
        NudgeMouse;
      end;
    end;
  end;
end;

procedure StartMoverThread;
begin
  InitXtst;
  with TMoverThread.Create(False) do
    FreeOnTerminate := True;
end;

end.
