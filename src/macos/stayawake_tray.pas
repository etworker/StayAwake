unit stayawake_tray;

{$mode objfpc}{$H+}
{$modeswitch objectivec1}

interface

procedure TrayCreate;

implementation

uses
  SysUtils,
  Classes,
  stayawake_common,
  stayawake_mover,
  CocoaAll,
  MacOSAll;

// Platform renderer for the shared tray core (stayawake_common): it binds the
// declarative menu tree to NSStatusItem/NSMenu and implements the platform
// hooks (assertions, quit, about). All strings, menu structure, state queries
// and click dispatching live in common and are identical on Linux/Windows.

type
  TStayAwakeApp = objcclass(NSObject)
  public
    procedure trayAction(sender: id); message 'trayAction:';
  end;

  TItemBinding = record
    Node: PMenuNode;
    Item: NSMenuItem;
  end;

var
  StatusItem: NSStatusItem = nil;
  AppDelegate: TStayAwakeApp = nil;
  MenuRoot: PMenuNode = nil;
  Bindings: array of TItemBinding;

function MakeTrayNSImage: NSImage; forward;
function MakeEyeNSImage(Px, Pt: Integer; Template: Boolean): NSImage; forward;

// ---- Platform hooks ---------------------------------------------------------

procedure HookRefreshVisual; cdecl;
var
  img: NSImage;
  i: Integer;
begin
  if StatusItem = nil then
    Exit;
  img := MakeTrayNSImage;
  if img <> nil then
  begin
    StatusItem.setImage(img);
    img.release;
  end;
  StatusItem.setToolTip(NSString.stringWithUTF8String(PChar(TrayTooltip)));
  for i := 0 to High(Bindings) do
    with Bindings[i] do
      case Node^.Kind of
        mkCheck, mkRadio:
        begin
          if MenuActionState(Node^.Action) then
            Item.setState(NSOnState)
          else
            Item.setState(NSOffState);
        end;
      end;
end;

procedure HookApplyAwake; cdecl;
begin
  UpdateExecutionState;
end;

procedure HookApplyLidMode; cdecl;
begin
  LidGuardApply;
end;

procedure HookApplyLanguage; cdecl;
var
  i: Integer;
begin
  for i := 0 to High(Bindings) do
    Bindings[i].Item.setTitle(
      NSString.stringWithUTF8String(PChar(L(Bindings[i].Node^.Text))));
  HookRefreshVisual;
end;

procedure HookShowAbout; cdecl;
var
  alert: NSAlert;
  info: string;
  icon: NSImage;
begin
  alert := NSAlert.alloc.init;
  alert.setMessageText(NSString.stringWithUTF8String(PChar(L(SAbout))));
  info := AboutText + #10#10 +
      '合盖行为(接电源时)可在托盘菜单切换(Apple Silicon)。';
  alert.setInformativeText(NSString.stringWithUTF8String(PChar(info)));
  // The bundle ships no .icns, so NSAlert would fall back to the generic
  // system app icon; show the colored eye instead (same artwork as the tray).
  icon := MakeEyeNSImage(256, 64, False);
  if icon <> nil then
  begin
    alert.setIcon(icon);
    icon.release;
  end;
  alert.addButtonWithTitle(NSString.stringWithUTF8String('OK'));
  alert.runModal;
  alert.release;
end;

procedure HookQuit; cdecl;
begin
  NSApplication(NSApp).terminate(nil);
end;

function HookSystemLang: string; cdecl;
var
  langs: NSArray;
  s: NSString;
begin
  // FPC 3.2.2 cocoa bindings lack NSLocale.languageCode; the AppleLanguages
  // user default carries the same information ("zh-Hans-CN" style entries).
  Result := '';
  langs := NSUserDefaults.standardUserDefaults.objectForKey(
    NSString.stringWithUTF8String('AppleLanguages'));
  if (langs <> nil) and (langs.count > 0) then
  begin
    s := NSString(langs.objectAtIndex(0));
    if s <> nil then
    begin
      Result := LowerCase(s.UTF8String);
      if Pos('-', Result) > 0 then
        Result := Copy(Result, 1, Pos('-', Result) - 1);
    end;
  end;
end;

// ---- Menu construction ------------------------------------------------------

procedure TStayAwakeApp.trayAction(sender: id);
begin
  MenuActionInvoke(TMenuAction(NSMenuItem(sender).tag));
end;

function NewMenuItemFor(Node: PMenuNode): NSMenuItem;
begin
  Result := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSString.stringWithUTF8String(PChar(L(Node^.Text))),
    objcselector('trayAction:'), NSString.stringWithUTF8String(''));
  Result.setTarget(AppDelegate);
  Result.setTag(NSInteger(Node^.Action));
end;

procedure Bind(Node: PMenuNode; Item: NSMenuItem);
var
  n: Integer;
begin
  n := Length(Bindings);
  SetLength(Bindings, n + 1);
  Bindings[n].Node := Node;
  Bindings[n].Item := Item;
end;

procedure FillMenu(Dest: NSMenu; Parent: PMenuNode);
var
  i: Integer;
  node: PMenuNode;
  item, sub: NSMenuItem;
  subMenu: NSMenu;
begin
  Dest.setAutoenablesItems(False);
  for i := 0 to High(Parent^.Sub) do
  begin
    node := Parent^.Sub[i];
    case node^.Kind of
      mkSep:
        Dest.addItem(NSMenuItem.separatorItem);
      mkSubmenu:
      begin
        subMenu := NSMenu.alloc.initWithTitle(
          NSString.stringWithUTF8String(PChar(L(node^.Text))));
        subMenu.setAutoenablesItems(False);
        FillMenu(subMenu, node);
        sub := NewMenuItemFor(node);
        sub.setSubmenu(subMenu);
        subMenu.release;
        Dest.addItem(sub);
        Bind(node, sub);
      end;
    else
      item := NewMenuItemFor(node);
      Dest.addItem(item);
      Bind(node, item);
    end;
  end;
end;

// ---- Tray icon artwork ------------------------------------------------------

// Render the shared eye artwork at any size. Template=True lets the system
// re-color for dark/light menu bars; the About dialog wants the colored eye.
function MakeEyeNSImage(Px, Pt: Integer; Template: Boolean): NSImage;
var
  Pixels: array of Byte;
  cs: CGColorSpaceRef;
  data: CFDataRef;
  provider: CGDataProviderRef;
  cg: CGImageRef;
  sz: NSSize;
begin
  Result := nil;
  SetLength(Pixels, Px * Px * 4);
  GenerateIconPixels(Px, AppActive, @Pixels[0]);
  cs := CGColorSpaceCreateDeviceRGB;
  if cs = nil then
    Exit;
  // CFDataCreate copies the bytes, so the on-stack pixel buffer is safe even
  // after this function returns and the image is drawn lazily later.
  data := CFDataCreate(nil, @Pixels[0], Length(Pixels));
  provider := nil;
  cg := nil;
  if data <> nil then
    provider := CGDataProviderCreateWithCFData(data);
  if provider <> nil then
    cg := CGImageCreate(Px, Px, 8, 32, Px * 4,
      cs, kCGImageAlphaPremultipliedLast, provider, nil, 0, kCGRenderingIntentDefault);
  if (provider <> nil) and (cg <> nil) then
  begin
    sz := NSMakeSize(Pt, Pt);
    Result := NSImage(NSImage.alloc).initWithCGImage_size(cg, sz);
    if Template then
      Result.setTemplate(True);
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

function MakeTrayNSImage: NSImage;
const
  // 36 px @ 18 pt = 2x; menu-bar status items draw at ~18 pt, so this stays
  // crisp on Retina instead of being scaled up from a 32 px bitmap.
  ImgPx = 36;
  ImgPt = 18;
begin
  Result := MakeEyeNSImage(ImgPx, ImgPt, True);
end;

// ---- Entry point ------------------------------------------------------------

procedure TrayCreate;
var
  app: NSApplication;
  menu: NSMenu;
  img: NSImage;
begin
  app := NSApplication.sharedApplication;
  app.setActivationPolicy(NSApplicationActivationPolicyAccessory);
  app.finishLaunching;

  TrayConfigDir := GetEnvironmentVariable('HOME');
  if TrayConfigDir <> '' then
    TrayConfigDir := TrayConfigDir + '/Library/Application Support';

  TrayHooks.HasLid := True;
  TrayHooks.RefreshVisual := @HookRefreshVisual;
  TrayHooks.ApplyAwake := @HookApplyAwake;
  TrayHooks.ApplyLidMode := @HookApplyLidMode;
  TrayHooks.ApplyLanguage := @HookApplyLanguage;
  TrayHooks.ShowAbout := @HookShowAbout;
  TrayHooks.Quit := @HookQuit;
  TraySystemLang := @HookSystemLang;

  AppDelegate := TStayAwakeApp.alloc.init;

  StatusItem := NSStatusBar.systemStatusBar.statusItemWithLength(NSSquareStatusItemLength);
  StatusItem.retain;
  StatusItem.setHighlightMode(True);

  img := MakeTrayNSImage;
  if img <> nil then
  begin
    StatusItem.setImage(img);
    img.release;
  end;

  MenuRoot := BuildTrayMenu(TrayHooks.HasLid);
  menu := NSMenu.alloc.initWithTitle(NSString.stringWithUTF8String('StayAwake'));
  FillMenu(menu, MenuRoot);

  StatusItem.setMenu(menu);
  menu.release;

  HookRefreshVisual;
  app.run;
end;

finalization
  FreeTrayMenu(MenuRoot);

end.
