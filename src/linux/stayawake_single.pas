unit stayawake_single;

{$mode objfpc}{$H+}

interface

function AcquireSingleInstance: Boolean;

implementation

uses
  BaseUnix,
  Unix;

const
  LockPath = '/tmp/stayawake_single.lock';

var
  LockFd: cInt = -1;

function AcquireSingleInstance: Boolean;
begin
  Result := False;
  LockFd := FpOpen(LockPath, O_RDWR or O_CREAT, &644);
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