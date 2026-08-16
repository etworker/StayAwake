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

function IsAutoStartEnabled: Boolean;
var
  r: TRegistry;
begin
  Result := False;
  r := NewReg;
  try
    if not r.OpenKeyReadOnly(RunKey) then
      Exit;
    try
      Result := r.ValueExists(APP_NAME) and (r.ReadString(APP_NAME) <> '');
    finally
      r.CloseKey;
    end;
  finally
    r.Free;
  end;
end;

procedure EnsureAutoStart;
var
  r: TRegistry;
  ExePath: string;
begin
  if IsAutoStartEnabled then
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
