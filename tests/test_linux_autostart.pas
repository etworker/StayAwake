{$mode objfpc}{$H+}
program test_linux_autostart;

{ Scenario tests for the Linux XDG autostart semantics in
  src/linux/stayawake_autostart.pas. Runs on Linux only (uses the linux
  unit set); each run takes a scenario name and an isolated $HOME so runs
  never touch the real config:

    HOME=/tmp/h1 ./test_linux_autostart s1
    HOME=        ./test_linux_autostart s5     (empty HOME edge case)

  Scenarios:
    s1  first run creates the .desktop entry (quoted Exec, enabled)
    s2  path matches + enabled -> EnsureAutoStart does not rewrite
    s3  GNOME-style disable (=false in place): startup sync respects it,
        EnableAutoStart force-re-enables
    s4  stale Exec path is refreshed by startup sync
    s5  empty HOME: no crash, no file }

uses
  SysUtils, Classes, stayawake_common, stayawake_autostart;

procedure Check(const n: string; c: Boolean);
begin
  if c then
    WriteLn('PASS: ', n)
  else
  begin
    WriteLn('FAIL: ', n);
    ExitCode := 1;
  end;
end;

function ReadAll(const F: string): string;
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.LoadFromFile(F);
    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

procedure WriteF(const F, c: string);
var
  sl: TStringList;
begin
  ForceDirectories(ExtractFilePath(F));
  sl := TStringList.Create;
  try
    sl.Text := c;
    sl.SaveToFile(F);
  finally
    sl.Free;
  end;
end;

var
  F, Exe: string;
begin
  F := GetEnvironmentVariable('HOME') + '/.config/autostart/stayawake.desktop';
  Exe := ExpandFileName(ParamStr(0));
  case ParamStr(1) of
    's1':
    begin
      EnsureAutoStart;
      Check('s1 file created', FileExists(F));
      if FileExists(F) then
      begin
        Check('s1 quoted Exec', Pos('Exec="' + Exe + '"', ReadAll(F)) > 0);
        Check('s1 enabled=true', Pos('X-GNOME-Autostart-enabled=true', ReadAll(F)) > 0);
      end;
      Check('s1 IsAutoStartEnabled', IsAutoStartEnabled);
    end;
    's2':
    begin
      WriteF(F, '[Desktop Entry]'#10 + 'Exec="' + Exe + '"'#10 +
        'X-GNOME-Autostart-enabled=true'#10);
      EnsureAutoStart;
      Check('s2 matching+enabled untouched', IsAutoStartEnabled);
    end;
    's3':
    begin
      WriteF(F, '[Desktop Entry]'#10 + 'Exec="' + Exe + '"'#10 +
        'X-GNOME-Autostart-enabled=false'#10);
      Check('s3 disabled detected', not IsAutoStartEnabled);
      EnsureAutoStart;
      Check('s3 startup sync respects disable', not IsAutoStartEnabled);
      EnableAutoStart;
      Check('s3 EnableAutoStart re-enables', IsAutoStartEnabled);
      if FileExists(F) then
        Check('s3 enabled=true written', Pos('X-GNOME-Autostart-enabled=true', ReadAll(F)) > 0);
    end;
    's4':
    begin
      WriteF(F, '[Desktop Entry]'#10 + 'Exec="/nonexistent/old"'#10 +
        'X-GNOME-Autostart-enabled=true'#10);
      EnsureAutoStart;
      if FileExists(F) then
        Check('s4 stale Exec refreshed', Pos('Exec="' + Exe + '"', ReadAll(F)) > 0);
      Check('s4 enabled', IsAutoStartEnabled);
    end;
    's5':
    begin
      EnsureAutoStart;
      EnableAutoStart;
      Check('s5 empty HOME safe', not FileExists(F));
    end;
  else
    WriteLn('unknown scenario');
    ExitCode := 2;
  end;
end.
