unit stayawake_mover;

{$mode objfpc}{$H+}

interface

uses
  stayawake_common;

procedure StartMoverThread;
procedure UpdateExecutionState;
procedure WakeMoverThread;

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

function SetThreadExecutionState(esFlags: DWORD): DWORD; stdcall;
  external 'kernel32' name 'SetThreadExecutionState';

// Tell Windows we are actively presenting so it must not blank the display
// or enter sleep. Mirrors the reliable part the mouse-nudge hack cannot do.
// SetThreadExecutionState is per-thread: the tray handlers run on the main
// thread and can only clear its own flags, so the mover thread must refresh
// this itself on every tick and be woken when the app is paused.
procedure UpdateExecutionState;
begin
  if AppActive then
    SetThreadExecutionState(ES_CONTINUOUS or ES_SYSTEM_REQUIRED or ES_DISPLAY_REQUIRED)
  else
    SetThreadExecutionState(ES_CONTINUOUS);
end;
{$ENDIF}

var
  WakeEvent: TEvent = nil;

procedure WakeMoverThread;
begin
  if WakeEvent <> nil then
    WakeEvent.SetEvent;
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
begin
  while not Terminated do
  begin
    if WakeEvent <> nil then
    begin
      WakeEvent.WaitFor(INTERVAL_SECS * 1000);
      WakeEvent.ResetEvent;
    end
    else
      Sleep(INTERVAL_SECS * 1000);
    if AppActive then
      NudgeMouse;
    // Unconditional: only this thread can clear the ES_* flags it set while
    // active, so pausing must be able to take effect here.
    UpdateExecutionState;
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
