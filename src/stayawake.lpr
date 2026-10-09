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

  // Always start in the Working (active) state; there is no CLI flag, the
  // default is intentionally "active".
  AppActive := True;
  UpdateExecutionState;

  EnsureAutoStart;
  StartMoverThread;
  TrayCreate;
end.
