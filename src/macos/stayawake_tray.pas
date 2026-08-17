unit stayawake_tray;

{$mode objfpc}{$H+}
{$modeswitch objectivec1}

interface

procedure TrayCreate;

implementation

uses
  SysUtils,
  stayawake_common,
  stayawake_autostart,
  CocoaAll,
  MacOSAll;

type
  TStayAwakeApp = objcclass(NSObject)
  public
    procedure toggleAwake(sender: id); message 'toggleAwake:';
    procedure startAwake(sender: id); message 'startAwake:';
    procedure stopAwake(sender: id); message 'stopAwake:';
    procedure toggleAutostart(sender: id); message 'toggleAutostart:';
    procedure showAbout(sender: id); message 'showAbout:';
    procedure quitApp(sender: id); message 'quitApp:';
  end;

var
  StatusItem: NSStatusItem = nil;
  MenuStart: NSMenuItem = nil;
  MenuStop: NSMenuItem = nil;
  MenuAutostart: NSMenuItem = nil;
  AppDelegate: TStayAwakeApp = nil;

procedure TraySetVisual; forward;

procedure TStayAwakeApp.toggleAwake(sender: id);
begin
  AppActive := not AppActive;
  TraySetVisual;
end;

procedure TStayAwakeApp.startAwake(sender: id);
begin
  if not AppActive then
  begin
    AppActive := True;
    TraySetVisual;
  end;
end;

procedure TStayAwakeApp.stopAwake(sender: id);
begin
  if AppActive then
  begin
    AppActive := False;
    TraySetVisual;
  end;
end;

procedure TStayAwakeApp.toggleAutostart(sender: id);
begin
  if IsAutoStartEnabled then
    DisableAutoStart
  else
    EnsureAutoStart;
  TraySetVisual;
end;

procedure TStayAwakeApp.showAbout(sender: id);
var
  alert: NSAlert;
  info: string;
begin
  alert := NSAlert.alloc.init;
  alert.setMessageText(NSString.stringWithUTF8String('About StayAwake'));
  info := APP_NAME + ' ' + APP_VERSION + #10 + #10 +
    'Prevents the system from sleeping by moving the mouse every ' +
    IntToStr(INTERVAL_SECS) + ' seconds.';
  alert.setInformativeText(NSString.stringWithUTF8String(PChar(info)));
  alert.addButtonWithTitle(NSString.stringWithUTF8String('OK'));
  alert.runModal;
  alert.release;
end;

procedure TStayAwakeApp.quitApp(sender: id);
begin
  NSApplication(NSApp).terminate(nil);
end;

function MakeStatusImage: NSImage;
var
  pixels: TIconPixels;
  cs: CGColorSpaceRef;
  data: CFDataRef;
  provider: CGDataProviderRef;
  cg: CGImageRef;
  sz: NSSize;
begin
  Result := nil;
  GenerateIconPixels(AppActive, pixels);
  cs := CGColorSpaceCreateDeviceRGB;
  if cs = nil then
    Exit;
  // CFDataCreate copies the bytes, so the on-stack pixel buffer is safe even
  // after this function returns and the image is drawn lazily later.
  data := CFDataCreate(nil, @pixels, SizeOf(pixels));
  provider := nil;
  cg := nil;
  if data <> nil then
    provider := CGDataProviderCreateWithCFData(data);
  if provider <> nil then
    cg := CGImageCreate(ICON_SIZE, ICON_SIZE, 8, 32, ICON_SIZE * 4,
      cs, kCGImageAlphaPremultipliedLast, provider, nil, 0, kCGRenderingIntentDefault);
  if (provider <> nil) and (cg <> nil) then
  begin
    sz := NSMakeSize(ICON_SIZE, ICON_SIZE);
    Result := NSImage(NSImage.alloc).initWithCGImage_size(cg, sz);
  end;
  if cs <> nil then
    CGColorSpaceRelease(cs);
  if data <> nil then
    CFRelease(data);
  if provider <> nil then
    CGDataProviderRelease(provider);
  if cg <> nil then
    CGImageRelease(cg);
end;

procedure TraySetVisual;
var
  img: NSImage;
begin
  if StatusItem = nil then
    Exit;
  img := MakeStatusImage;
  if img = nil then
    Exit;
  StatusItem.setImage(img);
  if AppActive then
    StatusItem.setToolTip(NSString.stringWithUTF8String('StayAwake - Working'))
  else
    StatusItem.setToolTip(NSString.stringWithUTF8String('StayAwake - Paused'));
  if MenuStart <> nil then
    MenuStart.setEnabled(not AppActive);
  if MenuStop <> nil then
    MenuStop.setEnabled(AppActive);
  if MenuAutostart <> nil then
  begin
    if IsAutoStartEnabled then
      MenuAutostart.setState(NSOnState)
    else
      MenuAutostart.setState(NSOffState);
  end;
  img.release;
end;

procedure TrayCreate;
var
  app: NSApplication;
  menu: NSMenu;
  aboutItem, quitItem: NSMenuItem;
  img: NSImage;
begin
  app := NSApplication.sharedApplication;
  app.setActivationPolicy(NSApplicationActivationPolicyAccessory);
  app.finishLaunching;

  AppDelegate := TStayAwakeApp.alloc.init;

  StatusItem := NSStatusBar.systemStatusBar.statusItemWithLength(NSSquareStatusItemLength);
  StatusItem.retain;
  StatusItem.setHighlightMode(True);

  img := MakeStatusImage;
  if img <> nil then
  begin
    StatusItem.setImage(img);
    img.release;
  end;

  menu := NSMenu.alloc.initWithTitle(NSString.stringWithUTF8String('StayAwake'));
  menu.setAutoenablesItems(False);

  MenuStart := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSString.stringWithUTF8String('Start Awake'), objcselector('startAwake:'), NSString.stringWithUTF8String(''));
  MenuStop := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSString.stringWithUTF8String('Stop Awake'), objcselector('stopAwake:'), NSString.stringWithUTF8String(''));
  MenuAutostart := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSString.stringWithUTF8String('Start on Login'), objcselector('toggleAutostart:'), NSString.stringWithUTF8String(''));
  aboutItem := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSString.stringWithUTF8String('About...'), objcselector('showAbout:'), NSString.stringWithUTF8String(''));
  quitItem := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSString.stringWithUTF8String('Quit'), objcselector('quitApp:'), NSString.stringWithUTF8String(''));

  MenuStart.setTarget(AppDelegate);
  MenuStop.setTarget(AppDelegate);
  MenuAutostart.setTarget(AppDelegate);
  aboutItem.setTarget(AppDelegate);
  quitItem.setTarget(AppDelegate);

  menu.addItem(MenuStart);
  menu.addItem(MenuStop);
  menu.addItem(NSMenuItem.separatorItem);
  menu.addItem(MenuAutostart);
  menu.addItem(NSMenuItem.separatorItem);
  menu.addItem(aboutItem);
  menu.addItem(NSMenuItem.separatorItem);
  menu.addItem(quitItem);

  StatusItem.setMenu(menu);
  menu.release;
  MenuStart.release;
  MenuStop.release;
  MenuAutostart.release;
  aboutItem.release;
  quitItem.release;

  TraySetVisual;
  app.run;
end;

end.