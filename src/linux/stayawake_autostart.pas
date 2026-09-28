unit stayawake_autostart;

{$mode objfpc}{$H+}

interface

procedure EnsureAutoStart;
procedure EnableAutoStart;
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
var
  sl: TStringList;
  i: Integer;
  s: string;
begin
  Result := False;
  if not FileExists(AutoStartPath) then
    Exit;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(AutoStartPath);
    except
      on E: Exception do
        Exit;
    end;
    Result := True;
    for i := 0 to sl.Count - 1 do
    begin
      s := Trim(sl[i]);
      if (Pos('X-GNOME-Autostart-enabled', s) = 1) and (Pos('=false', s) > 0) then
      begin
        Result := False;
        Exit;
      end;
    end;
  finally
    sl.Free;
  end;
end;

function AutoStartPathMatches: Boolean;
var
  sl: TStringList;
  i: Integer;
  s, ExePath: string;
begin
  Result := False;
  if not FileExists(AutoStartPath) then
    Exit;
  ExePath := ExpandFileName(ParamStr(0));
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(AutoStartPath);
      for i := 0 to sl.Count - 1 do
      begin
        s := Trim(sl[i]);
        if (Pos('Exec=', s) = 1) then
        begin
          s := Copy(s, 6, MaxInt);
          // Strip surrounding quotes if present
          if (Length(s) >= 2) and (s[1] = '"') and (s[Length(s)] = '"') then
            s := Copy(s, 2, Length(s) - 2);
          if SameText(s, ExePath) then
          begin
            Result := True;
            Exit;
          end;
        end;
      end;
    except
      on E: Exception do
        ;
    end;
  finally
    sl.Free;
  end;
end;

procedure WriteAutoStartFile;
var
  Path: string;
  sl: TStringList;
begin
  Path := AutoStartPath;
  if Path = '' then
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
    try
      sl.SaveToFile(Path);
    except
      // The autostart entry cannot be written in this environment (e.g. the
      // autostart directory is not writable). That must not crash the app;
      // StayAwake still runs normally, just without auto-start.
      on E: Exception do
        ;
    end;
  finally
    sl.Free;
  end;
end;

// Startup sync: create the entry when missing, refresh a stale path, but
// leave an existing entry (including one disabled via GNOME) untouched.
procedure EnsureAutoStart;
var
  Path: string;
begin
  Path := AutoStartPath;
  if (Path = '') or AutoStartPathMatches then
    Exit;
  WriteAutoStartFile;
end;

// Tray toggle: enable even when the entry exists but was disabled elsewhere
// (GNOME sets X-GNOME-Autostart-enabled=false in place, keeping the file).
procedure EnableAutoStart;
var
  Path: string;
begin
  Path := AutoStartPath;
  if (Path = '') or (AutoStartPathMatches and IsAutoStartEnabled) then
    Exit;
  WriteAutoStartFile;
end;

procedure DisableAutoStart;
begin
  if FileExists(AutoStartPath) then
    DeleteFile(AutoStartPath);
end;

end.