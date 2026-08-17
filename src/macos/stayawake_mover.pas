unit stayawake_mover;

{$mode objfpc}{$H+}

interface

uses
  stayawake_common;

procedure StartMoverThread;
procedure UpdateExecutionState;

implementation

uses
  Classes,
  SysUtils,
  dynlibs,
  ctypes,
  MacOSAll;

type
  CGPoint = record
    x: Double;
    y: Double;
  end;
  CGEventRef = Pointer;
  CGEventType = cint;
  TCGEventCreate = function(source: Pointer): CGEventRef; cdecl;
  TCGEventGetLocation = function(ev: CGEventRef): CGPoint; cdecl;
  TCGEventCreateMouseEvent = function(source: Pointer; mouseType: CGEventType;
                                      p: CGPoint; button: cint): CGEventRef; cdecl;
  TCGEventPost = procedure(tap: cint; ev: CGEventRef); cdecl;
  TCFRelease = procedure(cf: Pointer); cdecl;
  TIOPMAssertionCreateWithName = function(AssertionType: CFStringRef;
    AssertionLevel: cint; Reason: CFStringRef; var AssertionID: cuint32): cint; cdecl;
  TIOPMAssertionRelease = function(AssertionID: cuint32): cint; cdecl;

var
  CGHandle: TLibHandle;
  CGEventCreate: TCGEventCreate;
  CGEventGetLocation: TCGEventGetLocation;
  CGEventCreateMouseEvent: TCGEventCreateMouseEvent;
  CGEventPost: TCGEventPost;
  CGFRelease: TCFRelease;

  // macOS power-management assertion (IOPMAssertion) loaded dynamically so the
  // binary keeps working even if IOKit symbols are unavailable; the mouse
  // nudge in NudgeMouse() is the standalone fallback that still prevents sleep.
  PMHandle: TLibHandle = NilHandle;
  IOPMAssertionCreateWithName: TIOPMAssertionCreateWithName = nil;
  IOPMAssertionRelease: TIOPMAssertionRelease = nil;
  gAssertionID: cuint32 = 0;
  gAssertionOn: Boolean = False;

procedure InitCoreGraphics;
begin
  CGEventCreate := nil;
  CGEventGetLocation := nil;
  CGEventCreateMouseEvent := nil;
  CGEventPost := nil;
  CGFRelease := nil;

  CGHandle := LoadLibrary('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
  if CGHandle = NilHandle then
    CGHandle := LoadLibrary('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices');
  if CGHandle = NilHandle then
    Exit;
  CGEventCreate := TCGEventCreate(GetProcAddress(CGHandle, 'CGEventCreate'));
  CGEventGetLocation := TCGEventGetLocation(GetProcAddress(CGHandle, 'CGEventGetLocation'));
  CGEventCreateMouseEvent := TCGEventCreateMouseEvent(GetProcAddress(CGHandle, 'CGEventCreateMouseEvent'));
  CGEventPost := TCGEventPost(GetProcAddress(CGHandle, 'CGEventPost'));
  CGFRelease := TCFRelease(GetProcAddress(CGHandle, 'CFRelease'));
end;

procedure NudgeMouse;
const
  kCGEventMouseMoved = 5;
  kCGHIDEventTap = 0;
var
  cur, ev: CGEventRef;
  loc, loc2: CGPoint;
begin
  if (CGEventCreate = nil) or (CGEventGetLocation = nil) or
     (CGEventCreateMouseEvent = nil) or (CGEventPost = nil) then
    Exit;
  cur := CGEventCreate(nil);
  if cur = nil then
    Exit;
  loc := CGEventGetLocation(cur);
  if CGFRelease <> nil then
    CGFRelease(cur);

  loc2.x := loc.x + 1;
  loc2.y := loc.y;
  ev := CGEventCreateMouseEvent(nil, kCGEventMouseMoved, loc2, 0);
  if ev <> nil then
  begin
    CGEventPost(kCGHIDEventTap, ev);
    if CGFRelease <> nil then
      CGFRelease(ev);
  end;

  Sleep(50);

  ev := CGEventCreateMouseEvent(nil, kCGEventMouseMoved, loc, 0);
  if ev <> nil then
  begin
    CGEventPost(kCGHIDEventTap, ev);
    if CGFRelease <> nil then
      CGFRelease(ev);
  end;
end;

procedure InitPowerManagement;
begin
  if PMHandle <> NilHandle then
    Exit;
  PMHandle := LoadLibrary('/System/Library/Frameworks/IOKit.framework/IOKit');
  if PMHandle = NilHandle then
    Exit;
  IOPMAssertionCreateWithName := TIOPMAssertionCreateWithName(
    GetProcAddress(PMHandle, 'IOPMAssertionCreateWithName'));
  IOPMAssertionRelease := TIOPMAssertionRelease(
    GetProcAddress(PMHandle, 'IOPMAssertionRelease'));
end;

procedure UpdateExecutionState;
var
  reason, atype: CFStringRef;
  res: cint;
begin
  if AppActive then
  begin
    if gAssertionOn then
      Exit;
    if IOPMAssertionCreateWithName = nil then
      Exit;
    reason := CFStringCreateWithCString(nil, PAnsiChar('StayAwake keeps this Mac awake'),
      kCFStringEncodingUTF8);
    atype := CFStringCreateWithCString(nil, PAnsiChar('NoDisplaySleepAssertion'),
      kCFStringEncodingUTF8);
    res := -1;
    if (reason <> nil) and (atype <> nil) then
      res := IOPMAssertionCreateWithName(atype, 255, reason, gAssertionID);
    if reason <> nil then
      CFRelease(reason);
    if atype <> nil then
      CFRelease(atype);
    if res = 0 then
      gAssertionOn := True;
  end
  else
  begin
    if not gAssertionOn then
      Exit;
    if (IOPMAssertionRelease <> nil) and (gAssertionID <> 0) then
      IOPMAssertionRelease(gAssertionID);
    gAssertionID := 0;
    gAssertionOn := False;
  end;
end;

type
  TMoverThread = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TMoverThread.Execute;
begin
  while not Terminated do
  begin
    Sleep(INTERVAL_SECS * 1000);
    if AppActive and (not Terminated) then
      NudgeMouse;
  end;
end;

procedure StartMoverThread;
begin
  InitCoreGraphics;
  InitPowerManagement;
  UpdateExecutionState;
  TMoverThread.Create(False);
end;

initialization
  InitPowerManagement;

end.