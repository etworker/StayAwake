unit stayawake_autostart;

{$mode objfpc}{$H+}

interface

procedure EnsureAutoStart;
function IsAutoStartEnabled: Boolean;
procedure DisableAutoStart;

implementation

uses
  SysUtils,
  Classes,
  stayawake_common;

function AutoStartPath: string;
var
  ConfigDir, Home: string;
begin
  ConfigDir := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if ConfigDir = '' then
  begin
    Home := GetEnvironmentVariable('HOME');
    if Home = '' then
      Exit('');
    ConfigDir := Home + '/.config';
  end;
  Result := ConfigDir + '/autostart/stayawake.desktop';
end;

function IsAutoStartEnabled: Boolean;
begin
  Result := FileExists(AutoStartPath);
end;

procedure EnsureAutoStart;
var
  Path: string;
  sl: TStringList;
begin
  Path := AutoStartPath;
  if FileExists(Path) then
    Exit;
  if not ForceDirectories(ExtractFilePath(Path)) then
    Exit;
  sl := TStringList.Create;
  try
    sl.Add('[Desktop Entry]');
    sl.Add('Type=Application');
    sl.Add('Name=StayAwake');
    sl.Add('Comment=Prevent system sleep by moving the mouse');
    sl.Add('Exec="' + ExpandFileName(ParamStr(0)) + '"');
    sl.Add('X-GNOME-Autostart-enabled=true');
    sl.SaveToFile(Path);
  finally
    sl.Free;
  end;
end;

procedure DisableAutoStart;
begin
  if FileExists(AutoStartPath) then
    DeleteFile(AutoStartPath);
end;

end.