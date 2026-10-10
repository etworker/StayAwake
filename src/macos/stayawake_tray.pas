unit stayawake_tray;

{$mode objfpc}{$H+}
{$modeswitch objectivec1}

interface

procedure TrayCreate;

implementation

uses
  SysUtils,
  Classes,
  ctypes,
  stayawake_common,
  stayawake_mover,
  CocoaAll,
  MacOSAll;

// libc stdio for capturing `pmset -g custom` output (avoids a TProcess
// dependency; libc is always linked on darwin).
function popen(cmd: PAnsiChar; mode: PAnsiChar): Pointer; cdecl; external 'c' name 'popen';
function pclose(stream: Pointer): cint; cdecl; external 'c' name 'pclose';
function fgets(buf: PAnsiChar; size: cint; stream: Pointer): PAnsiChar; cdecl; external 'c' name 'fgets';

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

// ---- Lid close on AC (macOS): guided one-time admin command -----------------
// Userspace assertions cannot veto clamshell sleep on current macOS (tested:
// PreventSystemSleep held, lid close still slept). The only reliable software
// lever is `sudo pmset disablesleep`, which this app cannot run itself. So
// the menu reflects the real pmset state and picking a side shows a dialog
// with the exact one-time command (copied to the clipboard).

const
  SEnableCmd = 'sudo pmset -a disablesleep 1';
  SDisableCmd = 'sudo pmset -a disablesleep 0';

function PopenRead(const cmd: string): string;
const
  ReadBufSize = 512;
var
  f: Pointer;
  buf: array[0..ReadBufSize - 1] of AnsiChar;
  ln: PAnsiChar;
begin
  Result := '';
  f := popen(PAnsiChar(cmd), PAnsiChar('r'));
  if f = nil then
    Exit;
  try
    repeat
      ln := fgets(buf, ReadBufSize, f);
      if ln <> nil then
        Result := Result + string(ln);
    until ln = nil;
  finally
    pclose(f);
  end;
end;

function HookLidState: Boolean; cdecl;
var
  outp, line, value: string;
  i, start: Integer;
begin
  // The flag shows up in `pmset -g` as a tab-separated "SleepDisabled 1"
  // line. It does NOT appear in `pmset -g custom` on current macOS (verified
  // on a machine with the setting active), which the first version parsed.
  Result := False;
  outp := LowerCase(PopenRead('/usr/bin/pmset -g 2>/dev/null'));
  i := Pos('sleepdisabled', outp);
  if i = 0 then
    Exit;
  start := i + Length('sleepdisabled');
  line := Copy(outp, start, Length(outp));
  i := Pos(#10, line);
  if i > 0 then
    line := Copy(line, 1, i - 1);
  value := Trim(line);
  Result := (value <> '') and (value[1] = '1');
end;

procedure CopyToClipboard(const text: string);
var
  pb: NSPasteboard;
begin
  pb := NSPasteboard.generalPasteboard;
  pb.clearContents;
  pb.setString_forType(
    NSString.stringWithUTF8String(PChar(text)),
    NSString.stringWithUTF8String('public.utf8-plain-text'));
end;

procedure ShowLidGuideDialog(ABlock: Boolean);
var
  alert: NSAlert;
  info, cmd: string;
begin
  if ABlock then
  begin
    cmd := SEnableCmd;
    info :=
        'macOS 不允许普通应用拦截合盖睡眠,需要一次性管理员命令(终端中执行):' + #10#10 +
        cmd + #10#10 +
        '设置后插电合盖将不再睡眠(电池不受影响);' + #10 +
        '恢复命令:sudo pmset -a disablesleep 0' + #10#10 +
        '已复制到剪贴板,粘贴到终端回车即可。菜单勾选状态反映真实设置。' + #10 +
        'macOS 不允许普通应用拦截合盖,以上命令需要管理员权限。';
  end
  else
  begin
    cmd := SDisableCmd;
    info :=
        '恢复 macOS 默认合盖行为,请在终端执行一次性命令:' + #10#10 +
        cmd + #10#10 +
        '已复制到剪贴板,粘贴到终端回车即可。菜单勾选状态反映真实设置。';
  end;
  alert := NSAlert.alloc.init;
  alert.setMessageText(NSString.stringWithUTF8String(PChar(L(SLidTitle))));
  alert.setInformativeText(NSString.stringWithUTF8String(PChar(info)));
  alert.addButtonWithTitle(NSString.stringWithUTF8String('复制命令 / Copy'));
  alert.addButtonWithTitle(NSString.stringWithUTF8String('好 / OK'));
  if alert.runModal = NSAlertFirstButtonReturn then
    CopyToClipboard(cmd);
  alert.release;
end;

procedure HookLidRequest(ABlock: Boolean); cdecl;
var
  now: Boolean;
begin
  now := HookLidState;
  if ABlock = now then
    Exit; // already in the requested state
  ShowLidGuideDialog(ABlock);
  if Assigned(TrayHooks.RefreshVisual) then
    TrayHooks.RefreshVisual;
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

// Platform config/hooks must be ready BEFORE the main body starts:
// stayawake.lpr runs StartMoverThread (which applies the lid guard) prior
// to TrayCreate, so this is wired via the unit's initialization section
// (at the bottom) rather than from TrayCreate.
procedure InitPlatformConfig;
begin
  TrayConfigDir := GetEnvironmentVariable('HOME');
  if TrayConfigDir <> '' then
    TrayConfigDir := TrayConfigDir + '/Library/Application Support';

  TrayHooks.HasLid := True;
  TrayHooks.RefreshVisual := @HookRefreshVisual;
  TrayHooks.ApplyAwake := @HookApplyAwake;
  TrayHooks.ApplyLidMode := nil;
  TrayHooks.ApplyLanguage := @HookApplyLanguage;
  TrayHooks.ShowAbout := @HookShowAbout;
  TrayHooks.Quit := @HookQuit;
  TrayHooks.LidState := @HookLidState;
  TrayHooks.LidRequest := @HookLidRequest;
  TraySystemLang := @HookSystemLang;
end;

procedure TrayCreate;
var
  app: NSApplication;
  menu: NSMenu;
  img: NSImage;
begin
  app := NSApplication.sharedApplication;
  app.setActivationPolicy(NSApplicationActivationPolicyAccessory);
  app.finishLaunching;

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

initialization
  InitPlatformConfig;

finalization
  FreeTrayMenu(MenuRoot);

end.
