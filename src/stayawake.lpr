program stayawake;

{$mode objfpc}{$H+}
{$IFDEF WINDOWS}{$APPTYPE GUI}{$ENDIF}
{$IFDEF WINDOWS}{$R stayawake.rc}{$ENDIF}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  {$IFDEF WINDOWS}
  Windows,
  {$ENDIF}
  stayawake_common,
  stayawake_single,
  stayawake_mover,
  stayawake_autostart,
  stayawake_tray;

{$IFDEF WINDOWS}
function SetProcessDPIAware: BOOL; stdcall; external 'user32' name 'SetProcessDPIAware';
{$ENDIF}

var
  i: Integer;

begin
  {$IFDEF WINDOWS}
  // Mirror the Rust version: declare the process DPI-aware before any mouse
  // movement. Without this, on high-DPI displays Windows virtualizes
  // coordinates and the 1px nudge rounds to zero physical movement, so the
  // idle/screen-saver timer is never reset and the screen blanks anyway.
  SetProcessDPIAware;
  {$ENDIF}
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