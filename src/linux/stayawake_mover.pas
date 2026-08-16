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
  PDisplay = Pointer;
  TWindow = culong;
  PWindow = ^TWindow;
  TXOpenDisplay = function(name: PChar): PDisplay; cdecl;
  TXDefaultRootWindow = function(dpy: PDisplay): TWindow; cdecl;
  TXQueryPointer = function(dpy: PDisplay; w: TWindow; root, child: PWindow;
                            rx, ry, wx, wy: Pcint; mask: Pcuint): cint; cdecl;
  TXFlush = function(dpy: PDisplay): cint; cdecl;
  TXTestFakeMotionEvent = function(dpy: PDisplay; screen: cint; x, y: cint;
                                   delay: culong): cint; cdecl;

var
  XLib, XtstLib: TLibHandle;
  XOpenDisplay: TXOpenDisplay;
  XDefaultRootWindow: TXDefaultRootWindow;
  XQueryPointer: TXQueryPointer;
  XFlush: TXFlush;
  XTestFakeMotionEvent: TXTestFakeMotionEvent;
  XDpy: PDisplay;

procedure InitXtst;
begin
  XOpenDisplay := nil;
  XDefaultRootWindow := nil;
  XQueryPointer := nil;
  XFlush := nil;
  XTestFakeMotionEvent := nil;
  XDpy := nil;

  XLib := LoadLibrary('libX11.so.6');
  if XLib <> NilHandle then
  begin
    XOpenDisplay := TXOpenDisplay(GetProcAddress(XLib, 'XOpenDisplay'));
    XDefaultRootWindow := TXDefaultRootWindow(GetProcAddress(XLib, 'XDefaultRootWindow'));
    XQueryPointer := TXQueryPointer(GetProcAddress(XLib, 'XQueryPointer'));
    XFlush := TXFlush(GetProcAddress(XLib, 'XFlush'));
  end;

  XtstLib := LoadLibrary('libXtst.so.6');
  if XtstLib <> NilHandle then
    XTestFakeMotionEvent := TXTestFakeMotionEvent(GetProcAddress(XtstLib, 'XTestFakeMotionEvent'));

  if XOpenDisplay <> nil then
    XDpy := XOpenDisplay(nil);
end;

procedure NudgeMouse;
var
  root, child: TWindow;
  rootX, rootY, winX, winY: cint;
  mask: cuint;
begin
  if (XTestFakeMotionEvent = nil) or (XDpy = nil) or (XQueryPointer = nil) or
     (XDefaultRootWindow = nil) or (XFlush = nil) then
    Exit;
  root := XDefaultRootWindow(XDpy);
  child := 0;
  if XQueryPointer(XDpy, root, @root, @child, @rootX, @rootY, @winX, @winY, @mask) <> 0 then
  begin
    XTestFakeMotionEvent(XDpy, -1, rootX + 1, rootY, 0);
    XFlush(XDpy);
    Sleep(50);
    XTestFakeMotionEvent(XDpy, -1, rootX, rootY, 0);
    XFlush(XDpy);
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
  InitXtst;
  TMoverThread.Create(False);
end;

end.