unit stayawake_mover;

{$mode objfpc}{$H+}

interface

uses
  stayawake_common;

procedure StartMoverThread;
procedure UpdateExecutionState;

implementation

uses
  Classes,
  SysUtils,
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
procedure UpdateExecutionState;
begin
  if AppActive then
    SetThreadExecutionState(ES_CONTINUOUS or ES_SYSTEM_REQUIRED or ES_DISPLAY_REQUIRED)
  else
    SetThreadExecutionState(ES_CONTINUOUS);
end;
{$ENDIF}

procedure NudgeMouse;
var
  p: TPoint;
begin
  GetCursorPos(p);
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
    Sleep(INTERVAL_SECS * 1000);
    if AppActive and (not Terminated) then
    begin
      NudgeMouse;
      UpdateExecutionState;
    end;
  end;
end;

procedure StartMoverThread;
begin
  with TMoverThread.Create(False) do
    FreeOnTerminate := True;
end;

end.