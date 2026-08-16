unit stayawake_mover;

{$mode objfpc}{$H+}

interface

uses
  stayawake_common;

procedure StartMoverThread;

implementation

uses
  Classes,
  SysUtils,
  dynlibs,
  ctypes;

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

var
  CGHandle: TLibHandle;
  CGEventCreate: TCGEventCreate;
  CGEventGetLocation: TCGEventGetLocation;
  CGEventCreateMouseEvent: TCGEventCreateMouseEvent;
  CGEventPost: TCGEventPost;
  CFRelease: TCFRelease;

procedure InitCoreGraphics;
begin
  CGEventCreate := nil;
  CGEventGetLocation := nil;
  CGEventCreateMouseEvent := nil;
  CGEventPost := nil;
  CFRelease := nil;

  CGHandle := LoadLibrary('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
  if CGHandle = NilHandle then
    CGHandle := LoadLibrary('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices');
  if CGHandle = NilHandle then
    Exit;
  CGEventCreate := TCGEventCreate(GetProcAddress(CGHandle, 'CGEventCreate'));
  CGEventGetLocation := TCGEventGetLocation(GetProcAddress(CGHandle, 'CGEventGetLocation'));
  CGEventCreateMouseEvent := TCGEventCreateMouseEvent(GetProcAddress(CGHandle, 'CGEventCreateMouseEvent'));
  CGEventPost := TCGEventPost(GetProcAddress(CGHandle, 'CGEventPost'));
  CFRelease := TCFRelease(GetProcAddress(CGHandle, 'CFRelease'));
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
  if CFRelease <> nil then
    CFRelease(cur);

  loc2.x := loc.x + 1;
  loc2.y := loc.y;
  ev := CGEventCreateMouseEvent(nil, kCGEventMouseMoved, loc2, 0);
  if ev <> nil then
  begin
    CGEventPost(kCGHIDEventTap, ev);
    if CFRelease <> nil then
      CFRelease(ev);
  end;

  Sleep(50);

  ev := CGEventCreateMouseEvent(nil, kCGEventMouseMoved, loc, 0);
  if ev <> nil then
  begin
    CGEventPost(kCGHIDEventTap, ev);
    if CFRelease <> nil then
      CFRelease(ev);
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
  TMoverThread.Create(False);
end;

end.