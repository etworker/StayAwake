unit stayawake_autostart;

{$mode objfpc}{$H+}

interface

procedure EnsureAutoStart;
function IsAutoStartEnabled: Boolean;
procedure DisableAutoStart;

implementation

uses
  SysUtils,
  Registry,
  stayawake_common;

const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';

function NewReg: TRegistry;
begin
  Result := TRegistry.Create;
  Result.RootKey := HKEY_CURRENT_USER;
end;

function ReadRunValue: string;
var
  r: TRegistry;
begin
  Result := '';
  r := NewReg;
  try
    if not r.OpenKeyReadOnly(RunKey) then
      Exit;
    try
      if r.ValueExists(APP_NAME) then
        try
          Result := r.ReadString(APP_NAME);
        except
          // The value can hold a non-REG_SZ type (e.g. when edited by hand);
          // ReadString raises, and both callers run at startup or on every
          // tray-menu popup, where an exception would take the app down.
          on E: Exception do
            Result := '';
        end;
    finally
      r.CloseKey;
    end;
  finally
    r.Free;
  end;
end;

function IsAutoStartEnabled: Boolean;
begin
  Result := ReadRunValue <> '';
end;

function AutoStartPathMatches: Boolean;
begin
  Result := SameText(ReadRunValue, ExpandFileName(ParamStr(0)));
end;

procedure EnsureAutoStart;
var
  r: TRegistry;
  ExePath: string;
begin
  if AutoStartPathMatches then
    Exit;
  ExePath := ExpandFileName(ParamStr(0));
  r := NewReg;
  try
    if r.OpenKey(RunKey, True) then
    try
      r.WriteString(APP_NAME, ExePath);
    finally
      r.CloseKey;
    end;
  finally
    r.Free;
  end;
end;

procedure DisableAutoStart;
var
  r: TRegistry;
begin
  r := NewReg;
  try
    if r.OpenKey(RunKey, True) then
    try
      if r.ValueExists(APP_NAME) then
        r.DeleteValue(APP_NAME);
    finally
      r.CloseKey;
    end;
  finally
    r.Free;
  end;
end;

end.
