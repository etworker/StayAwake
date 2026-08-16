program stayawake;

{$mode objfpc}{$H+}
{$IFDEF WINDOWS}{$APPTYPE GUI}{$ENDIF}
{$IFDEF WINDOWS}{$R stayawake.rc}{$ENDIF}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  stayawake_common,
  stayawake_single,
  stayawake_mover,
  stayawake_autostart,
  stayawake_tray;

var
  i: Integer;

begin
  if not AcquireSingleInstance then
    Exit;

  StartActive := False;
  for i := 1 to ParamCount do
    if ParamStr(i) = '--start-active' then
      StartActive := True;
  AppActive := StartActive;

  EnsureAutoStart;
  StartMoverThread;
  TrayCreate;
end.