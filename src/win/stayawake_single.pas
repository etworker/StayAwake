unit stayawake_single;

{$mode objfpc}{$H+}

interface

function AcquireSingleInstance: Boolean;

implementation

uses
  Windows;

var
  MutexHandle: THandle = 0;

function AcquireSingleInstance: Boolean;
begin
  Result := False;
  MutexHandle := CreateMutexA(nil, False, 'Local\stayawake_single_instance');
  if MutexHandle = 0 then
    Exit;
  if GetLastError = ERROR_ALREADY_EXISTS then
  begin
    CloseHandle(MutexHandle);
    MutexHandle := 0;
    Exit;
  end;
  Result := True;
end;

end.