unit stayawake_mover;

{$MODE objfpc}
{$H+}

interface

uses
  stayawake_common;

procedure StartMoverThread;
procedure UpdateExecutionState;
procedure WakeMoverThread;
// Put the machine to sleep (drops the ES flags, enables the shutdown
// privilege, SetSuspendState, then re-applies ES per AppActive).
procedure SleepNow;
// Tray calls this when the lid switch state changes (GUID_LIDSWITCH_STATE_CHANGE).
procedure NotifyLidState(AClosed: Boolean);
// Diagnostic trail for the lid policy (%TEMP%\stayawake_lid.log).
procedure LidLog(const S: string);

implementation

uses
  Classes,
  SysUtils,
  SyncObjs,
  Windows;

{$IFDEF WINDOWS}
const
  ES_SYSTEM_REQUIRED = $00000001;
  ES_DISPLAY_REQUIRED = $00000002;
  ES_CONTINUOUS = $80000000;

function SetThreadExecutionState(esFlags: DWORD): DWORD; stdcall; external 'kernel32' name 'SetThreadExecutionState';

// Explicit suspend request. The SE_SHUTDOWN_NAME privilege it needs is held
// (disabled) in every interactive user's token; EnableShutdownPrivilege
// flips it on, so no admin is required to put the machine to sleep.
function SetSuspendState(
    Hibernate,
    ForceCritical,
    DisableWakeEvent: LongBool
): LongBool; stdcall; external 'powrprof' name 'SetSuspendState';

// Own Pascal name for the Vista+ API to avoid clashing with whatever the
// Windows unit declares.
function GetTick64: Int64; stdcall; external 'kernel32' name 'GetTickCount64';
{$ENDIF}

// Tell Windows we are actively presenting so it must not blank the display
// or enter sleep. Mirrors the reliable part the mouse-nudge hack cannot do.
// SetThreadExecutionState is per-thread: the tray handlers run on the main
// thread and can only clear its own flags, so the mover thread must refresh
// this itself on every tick and be woken when the app is paused.
procedure UpdateExecutionState;
begin
{$IFDEF WINDOWS}
  if AppActive then
    SetThreadExecutionState(ES_CONTINUOUS or ES_SYSTEM_REQUIRED or ES_DISPLAY_REQUIRED)
  else
    SetThreadExecutionState(ES_CONTINUOUS);
{$ENDIF}
end;

var
  WakeEvent: TEvent = nil;

procedure WakeMoverThread;
begin
  if WakeEvent <> nil then
    WakeEvent.SetEvent;
end;

// ---- Lid-close policy (Windows, mirrors the macOS mover) --------------------
// Requires a one-time admin step: set the lid action to "Do nothing" for
// both AC and battery (scripts/setup-lid.cmd / powercfg), otherwise the
// kernel sleeps on close and nothing here can intercept it. After that the
// whole policy runs unprivileged:
//   AC close:      awake checkbox on -> stay awake (ES flags); off -> sleep now
//   battery close: mins = 0 -> sleep now; mins = N -> stay awake N minutes
//                  then sleep; mins < 0 -> stay awake until the battery dies
// After a timer sleep the policy stays hands-off until the lid opens again
// (waking by any other means with the lid closed does not re-arm it).

var
  gLidClosed: Boolean = False;
  gClosedAtMs: Int64 = 0;
  gHandledClose: Boolean = False; // already slept for this closing

procedure LidLog(const S: string);
var
  f: TextFile;
  Path: string;
  Buf: array[0..1023] of Char;
begin
  try
    Path := '.';
    if GetEnvironmentVariable('TEMP', Buf, SizeOf(Buf)) > 0 then
      Path := Buf;
    Path := Path + '\stayawake_lid.log';
    AssignFile(f, Path);
    if FileExists(Path) then
      Append(f)
    else
      Rewrite(f);
    try
      WriteLn(f, FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), ' ', S);
    finally
      CloseFile(f);
    end;
  except
    // logging must never take the app down
  end;
end;

procedure EnableShutdownPrivilege;
var
  hTok: THandle;
  tp, prev: TTokenPrivileges;
  prevLen: DWORD;
begin
  if not OpenProcessToken(GetCurrentProcess, TOKEN_ADJUST_PRIVILEGES or TOKEN_QUERY, hTok) then
    Exit;
  try
    if not LookupPrivilegeValue(nil, 'SeShutdownPrivilege', tp.Privileges[0].Luid) then
      Exit;
    tp.PrivilegeCount := 1;
    tp.Privileges[0].Attributes := SE_PRIVILEGE_ENABLED;
    AdjustTokenPrivileges(hTok, False, tp, SizeOf(tp), prev, prevLen);
  finally
    CloseHandle(hTok);
  end;
end;

// Put the machine to sleep: drop our own keep-awake flags first (mirrors the
// macOS policy dropping its assertion), then request the suspension. The
// call returns after the machine wakes; ES flags are re-applied per AppActive.
procedure SleepNow;
begin
  LidLog('suspending now');
  SetThreadExecutionState(ES_CONTINUOUS);
  EnableShutdownPrivilege;
  if SetSuspendState(False, False, False) then
    LidLog('resumed from suspend')
  else
    LidLog('SetSuspendState failed, GetLastError=' + IntToStr(GetLastError));
  UpdateExecutionState;
end;

procedure NotifyLidState(AClosed: Boolean);
begin
{$IFDEF WINDOWS}
  gLidClosed := AClosed;
  if AClosed then begin
    gClosedAtMs := GetTick64;
    gHandledClose := False;
  end;
  if AClosed then
    LidLog('lid closed')
  else
    LidLog('lid open');
  if WakeEvent <> nil then
    WakeEvent.SetEvent;
{$ENDIF}
end;

// One policy step; called from the mover loop on every tick. Fine-grained
// ticking (500 ms) only while a lid timer can be pending.
procedure LidPolicyTick;
var
  S: TSystemPowerStatus;
  onAC: Boolean;
  mins, pct, pctFloor: Integer;
begin
  if not gLidClosed or gHandledClose then
    Exit;
  if not GetSystemPowerStatus(S) then
    Exit;
  onAC := S.ACLineStatus = 1;
  mins := LidBatteryMinutes;
  pct := S.BatteryLifePercent; // 255 = unknown
  pctFloor := LidBatteryPct;
  if onAC then begin
    if not LidAcAwake then begin
      gHandledClose := True;
      LidLog('AC close, awake checkbox off -> sleep now');
      SleepNow;
    end;
    // awake checkbox on: the ES flags hold the machine; nothing to enforce
  end
  else begin
    // Battery: two sleep conditions race, first one wins - the lid timer
    // expiring, or charge reaching the low-battery floor. The floor is
    // timer-mode independent (it also bounds the mins < 0 option); 255
    // (unknown charge) never triggers it.
    if (pct <> 255) and (pctFloor > 0) and (pct <= pctFloor) then begin
      gHandledClose := True;
      LidLog(Format('battery low (%d%% <= %d%% floor): sleeping', [pct, pctFloor]));
      SleepNow;
    end
    else if mins = 0 then begin
      gHandledClose := True;
      LidLog('battery close, 0 min -> sleep now');
      SleepNow;
    end
    else if mins > 0 then begin
      // Window still running: the fine-grained loop re-checks every 500 ms.
      if (GetTick64 - gClosedAtMs) >= Int64(mins) * 60000 then begin
        gHandledClose := True;
        LidLog(Format('battery close, %d min elapsed -> sleep', [mins]));
        SleepNow;
      end;
    end;
    // mins < 0 without a floor hit: stay awake until the battery dies
  end;
end;

procedure NudgeMouse;
var
  p: TPoint;
begin
  // On failure p would hold uninitialised stack data and the nudge would
  // teleport the cursor to a random spot. Skip this tick instead.
  if not GetCursorPos(p) then
    Exit;
  SetCursorPos(p.X + 1, p.Y);
  Sleep(50);
  SetCursorPos(p.X, p.Y);
end;

type
  TMoverThread = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TMoverThread.Execute;
var
  Fine: Boolean;
begin
  while not Terminated do begin
    // While the lid is closed a battery timer may be pending: tick finely.
    // Otherwise the original coarse cadence is enough.
    Fine := gLidClosed and not gHandledClose;
    if WakeEvent <> nil then begin
      if Fine then
        WakeEvent.WaitFor(500)
      else
        WakeEvent.WaitFor(INTERVAL_SECS * 1000);
      WakeEvent.ResetEvent;
    end
    else if Fine then
      Sleep(500)
    else
      Sleep(INTERVAL_SECS * 1000);
    if AppActive then
      NudgeMouse;
    // Unconditional: only this thread can clear the ES_* flags it set while
    // active, so pausing must be able to take effect here.
    UpdateExecutionState;
    LidPolicyTick;
  end;
end;

procedure StartMoverThread;
begin
  // Auto-reset event: each wake request releases exactly one wait. Windows'
  // TEvent takes PSecurityAttributes, so nil/empty-name = anonymous event.
  WakeEvent := TEvent.Create(nil, False, False, '');
  with TMoverThread.Create(False) do
    FreeOnTerminate := True;
end;

end.
