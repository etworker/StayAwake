unit stayawake_single;

{$mode objfpc}{$H+}

interface

function AcquireSingleInstance: Boolean;

implementation

uses
  SysUtils,
  BaseUnix,
  Unix;

// Per-user lock so one account's leftover file cannot block another account
// on a shared machine. Prefer XDG_RUNTIME_DIR (per-user, 0700, cleaned by the
// session); otherwise fall back to a UID-suffixed name in /tmp.
function LockPath: string;
var
  RuntimeDir, TmpDir: string;
begin
  RuntimeDir := GetEnvironmentVariable('XDG_RUNTIME_DIR');
  if RuntimeDir <> '' then
    Exit(RuntimeDir + '/stayawake.lock');
  TmpDir := GetEnvironmentVariable('TMPDIR');
  if TmpDir = '' then
    TmpDir := '/tmp';
  Result := TmpDir + '/stayawake_' + IntToStr(fpgetuid) + '.lock';
end;

var
  LockFd: cInt = -1;

function AcquireSingleInstance: Boolean;
begin
  Result := False;
  // 0600: only the owning user may open it, so a stale file from another
  // account can never make FpOpen fail with EACCES.
  LockFd := FpOpen(LockPath, O_RDWR or O_CREAT, &600);
  if LockFd < 0 then
    Exit;
  if FpFlock(LockFd, LOCK_EX or LOCK_NB) <> 0 then
  begin
    FpClose(LockFd);
    LockFd := -1;
    Exit;
  end;
  Result := True;
end;

end.
