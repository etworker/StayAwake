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
  CocoaAll;

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
begin
  alert := NSAlert.alloc.init;
  alert.setMessageText(NSString.stringWithUTF8String('About StayAwake'));
  alert.setInformativeText(NSString.stringWithUTF8String(
    APP_NAME + ' ' + APP_VERSION + #10 + #10 +
    'Prevents the system from sleeping by moving the mouse every ' +
    IntToStr(INTERVAL_SECS) + ' seconds.'));
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
  rep: NSBitmapImageRep;
  bd: PByte;
  sz: NSSize;
  i: Integer;
begin
  Result := nil;
  GenerateIconPixels(AppActive, pixels);
  rep := NSBitmapImageRep(NSBitmapImageRep.alloc).initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bitmapFormat_bytesPerRow_bitsPerPixel(
    nil, ICON_SIZE, ICON_SIZE, 8, 4, True, False, NSDeviceRGBColorSpace,
    0, ICON_SIZE * 4, 32);
  if rep = nil then
    Exit;
  bd := PByte(rep.bitmapData);
  if bd <> nil then
    for i := 0 to ICON_SIZE - 1 do
      Move(pixels[i * ICON_SIZE * 4], bd[i * ICON_SIZE * 4], ICON_SIZE * 4);
  sz := NSMakeSize(ICON_SIZE, ICON_SIZE);
  Result := NSImage(NSImage.alloc).initWithSize(sz);
  Result.addRepresentation(rep);
  rep.release;
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
      MenuAutostart.setState(NSControlStateValueOn)
    else
      MenuAutostart.setState(NSControlStateValueOff);
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
    NSString.stringWithUTF8String('Start Awake'), objcselector('startAwake:'), '');
  MenuStop := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSString.stringWithUTF8String('Stop Awake'), objcselector('stopAwake:'), '');
  MenuAutostart := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSString.stringWithUTF8String('Start on Login'), objcselector('toggleAutostart:'), '');
  aboutItem := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSString.stringWithUTF8String('About...'), objcselector('showAbout:'), '');
  quitItem := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSString.stringWithUTF8String('Quit'), objcselector('quitApp:'), '');

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