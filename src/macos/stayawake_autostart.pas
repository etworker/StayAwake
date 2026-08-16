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
  Home: string;
begin
  Home := GetEnvironmentVariable('HOME');
  if Home = '' then
    Exit('');
  Result := Home + '/Library/LaunchAgents/com.stayawake.plist';
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
    sl.Add('<?xml version="1.0" encoding="UTF-8"?>');
    sl.Add('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">');
    sl.Add('<plist version="1.0">');
    sl.Add('<dict>');
    sl.Add('  <key>Label</key>');
    sl.Add('  <string>com.stayawake</string>');
    sl.Add('  <key>ProgramArguments</key>');
    sl.Add('  <array>');
    sl.Add('    <string>' + ExpandFileName(ParamStr(0)) + '</string>');
    sl.Add('  </array>');
    sl.Add('  <key>RunAtLoad</key>');
    sl.Add('  <true/>');
    sl.Add('</dict>');
    sl.Add('</plist>');
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