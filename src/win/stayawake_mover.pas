unit stayawake_mover;

{$mode objfpc}{$H+}

interface

uses
  stayawake_common;

procedure StartMoverThread;

implementation

uses
  Classes,
  SysUtils,
  Windows;

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
      NudgeMouse;
  end;
end;

procedure StartMoverThread;
begin
  with TMoverThread.Create(False) do
    FreeOnTerminate := True;
end;

end.