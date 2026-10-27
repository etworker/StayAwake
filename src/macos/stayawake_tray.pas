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

// Platform renderer for the shared tray core (stayawake_common): it binds the
// declarative menu tree to NSStatusItem/NSMenu and implements the platform
// hooks (sleep cooperation, sleep-now, quit, about). All strings, menu
// structure, state queries and click dispatching live in common and are
// identical on Linux/Windows.

type
  TStayAwakeApp = objcclass(NSObject)
  public
    procedure trayAction(sender: id); message 'trayAction:';
    procedure menuNeedsUpdate(menu: NSMenu); message 'menuNeedsUpdate:';
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
procedure PowerLog(const s: string); forward;
const
  SEnableCmd = 'sudo pmset -a disablesleep 1';
  SDisableCmd = 'sudo pmset -a disablesleep 0';
function HookLidState: Boolean; cdecl; forward;
function PmsetSleepDisabled: Boolean; forward;
procedure ShowLidGuideDialog(ABlock: Boolean); forward;
procedure HookLidRequest(ABlock: Boolean); cdecl; forward;

// ---- libc helpers -----------------------------------------------------------

// libc stdio for capturing pmset output (avoids a TProcess dependency; libc
// is always linked on darwin). system() runs a command and waits.
function objc_getClass(name: PAnsiChar): id; cdecl; external 'objc' name 'objc_getClass';
function sel_getUid(name: PAnsiChar): SEL; cdecl; external 'objc' name 'sel_getUid';
function objc_msgSend_del(obj: id; sel: SEL; arg1: id): id; cdecl; external 'objc' name 'objc_msgSend';
function popen(cmd: PAnsiChar; mode: PAnsiChar): Pointer; cdecl; external 'c' name 'popen';
function pclose(stream: Pointer): cint; cdecl; external 'c' name 'pclose';
function fgets(buf: PAnsiChar; size: cint; stream: Pointer): PAnsiChar; cdecl; external 'c' name 'fgets';
function system(cmd: PAnsiChar): cint; cdecl; external 'c' name 'system';

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

// ---- Platform hooks ---------------------------------------------------------

// Re-read every checkable/radio state from the shared core. Called after
// any action and, via menuNeedsUpdate:, every time the menu is about to
// open - so states changed OUTSIDE the app (e.g. the user ran the lid
// guard command in a terminal) show up immediately.
procedure SyncMenuStates;
var
  i: Integer;
begin
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

procedure HookRefreshVisual; cdecl;
var
  img: NSImage;
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
  SyncMenuStates;
end;

procedure HookApplyAwake; cdecl;
begin
  UpdateExecutionState;
end;

// Run a shell command as root through the standard macOS authorization
// dialog. True = the command executed.
function RunRootCommand(const path: string; const args: array of string): Boolean;
const
  kAuthorizationFlagDefaults = 0;
  kAuthorizationFlagDestroyRights = 8;
  errAuthorizationCanceled = -60005;
type
  TAuthorizationCreate = function(rights: Pointer; environment: Pointer;
    flags: cuint32; var auth: Pointer): cint; cdecl;
  TAuthorizationExecuteWithPrivileges = function(auth: Pointer; path: PAnsiChar;
    flags: cuint32; args: PAnsiChar; pipe: Pointer): cint; cdecl;
  TAuthorizationFree = function(auth: Pointer; flags: cuint32): cint; cdecl;
var
  SecHandle: TLibHandle;
  gAuth: Pointer = nil;   // cached authorization ref: one password per run
  aCreate: TAuthorizationCreate;
  aExec: TAuthorizationExecuteWithPrivileges;
  aFree: TAuthorizationFree;
  argv: array of PAnsiChar;
  i: Integer;
  status: cint;
begin
  Result := False;
  SecHandle := LoadLibrary('/System/Library/Frameworks/Security.framework/Security');
  if SecHandle = NilHandle then
    Exit;
  Pointer(aCreate) := GetProcAddress(SecHandle, 'AuthorizationCreate');
  Pointer(aExec) := GetProcAddress(SecHandle, 'AuthorizationExecuteWithPrivileges');
  Pointer(aFree) := GetProcAddress(SecHandle, 'AuthorizationFree');
  if (aCreate = nil) or (aExec = nil) or (aFree = nil) then
    Exit;

  SetLength(argv, Length(args) + 1);
  for i := 0 to High(args) do
    argv[i] := PAnsiChar(AnsiString(args[i]));
  argv[High(argv)] := nil;

  // gAuth is created once per app run and REUSED: after the first password
  // the acquired right stays valid for this authorization ref, so later
  // elevated operations (Sleep Now, lid mode switches) do not re-prompt.
  // A denied status means the right expired - refresh the ref once.
  if gAuth = nil then
    if aCreate(nil, nil, kAuthorizationFlagDefaults, gAuth) <> 0 then
      Exit;

  status := aExec(gAuth, PAnsiChar(AnsiString(path)),
    kAuthorizationFlagDefaults, PAnsiChar(@argv[0]), nil);
  if status = errAuthorizationDenied then
  begin
    aFree(gAuth, kAuthorizationFlagDestroyRights);
    gAuth := nil;
    if aCreate(nil, nil, kAuthorizationFlagDefaults, gAuth) <> 0 then
      Exit;
    status := aExec(gAuth, PAnsiChar(AnsiString(path)),
      kAuthorizationFlagDefaults, PAnsiChar(@argv[0]), nil);
  end;
  Result := status = 0;
end;

procedure HookSleepNow; cdecl;
begin
  if not PmsetSleepDisabled then
  begin
    // Guard off: plain rootless sleep.
    system('/usr/bin/pmset sleepnow');
    Exit;
  end;
  // Guard on: disablesleep blocks every sleep request, including this one,
  // so run one elevated command that lifts the guard, sleeps, and re-arms
  // ~20 s after the machine wakes (the root shell is frozen while asleep,
  // so the 20 s count effectively resumes on wake). One password, guard
  // restored automatically.
  PowerLog('SleepNow with guard on: lifting via authorization dialog');
  if RunRootCommand('/bin/sh', ['-c',
      '/usr/bin/pmset -a disablesleep 0; /usr/bin/pmset sleepnow; sleep 20; /usr/bin/pmset -a disablesleep 1'])
  then
    PowerLog('SleepNow cycle dispatched')
  else
  begin
    PowerLog('SleepNow authorization canceled/failed');
    ShowLidGuideDialog(True);   // fallback: the clipboard guide
  end;
end;

// ---- Lid close (macOS): guided one-time admin command -----------------------
// `pmset -a disablesleep 1` keeps the machine awake with the lid closed (on
// any power source). It needs elevation once; the menu drives it through the
// clipboard-guide dialog. The tray radio reflects the REAL pmset state
// (SleepDisabled flag in `pmset -g`).

function PmsetSleepDisabled: Boolean;
var
  outp, line: string;
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
  line := Trim(line);
  Result := (line <> '') and (line[1] = '1');
end;

function HookLidState: Boolean; cdecl;
var
  outp, line: string;
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
  line := Trim(line);
  Result := (line <> '') and (line[1] = '1');
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
        '设置后合盖将保持唤醒(插电与电池均如此);' + #10 +
        '需要休眠时使用本菜单的「立即睡眠」;' + #10 +
        '恢复命令:sudo pmset -a disablesleep 0' + #10#10 +
        '点「复制命令」后在终端粘贴执行即可。菜单勾选状态反映真实设置。';
  end
  else
  begin
    cmd := SDisableCmd;
    info :=
        '恢复 macOS 默认合盖行为,请执行一次性命令:' + #10#10 +
        cmd + #10#10 +
        '点「复制命令」后在终端粘贴执行即可。菜单勾选状态反映真实设置。';
  end;
  alert := NSAlert.alloc.init;
  alert.setMessageText(NSString.stringWithUTF8String(PChar(L(LidTextTitle))));
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
  info := AboutText;
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

// ---- System sleep cooperation (macOS) ---------------------------------------
// Userspace cannot veto clamshell sleep on current macOS - exhaustively
// verified: power assertions are ignored, IOCancelPowerChange only delays
// the sleep by ~5 s, and `pmset disablesleep` would also kill the Apple-menu
// Sleep item. Manual sleep must keep working, so this app always COOPERATES:
// powerd broadcasts kIOMessageSystemWillSleep (30 s ack window) and the app
// answers IOAllowPowerChange immediately, dropping the keep-awake assertion
// for the duration (re-armed on wake while still active).
//
// NOTE: the delivered messages are the IOService.h kIOMessage* values
// (0xE0000270/80/300/320/330), NOT the 0xE0000200-series kIOPMMessage*
// constants from IOPMLib - the wrong family makes the handler fall through
// and sleep stalls 30 s (powerd: "stayawake timed out").
//
// The menu's "Sleep Now" item goes through `pmset sleepnow`, which is an
// explicit request and still works while SleepDisabled=1 is armed by the
// lid guard (verified on-device).

procedure PowerLog(const s: string);
var
  f: TextFile;
begin
  AssignFile(f, '/tmp/stayawake_power.log');
  if FileExists('/tmp/stayawake_power.log') then
    Append(f)
  else
    Rewrite(f);
  try
    WriteLn(f, FormatDateTime('hh:nn:ss.zzz', Now), ' ', s);
  finally
    CloseFile(f);
  end;
end;

const
  kIOMessageCanSystemSleep         = $E0000270;
  kIOMessageSystemWillSleep        = $E0000280;
  kIOMessageSystemWillNotSleep     = $E0000290;
  kIOMessageSystemCapabilityChange = $E0000300;
  kIOMessageSystemWillPowerOn      = $E0000320;
  kIOMessageSystemHasPoweredOn     = $E0000330;

type
  TIORegisterForSystemPower = function(refcon: Pointer; var port: Pointer;
    handler: Pointer; var notifier: Pointer): Pointer; cdecl;
  TIONotificationPortGetRunLoopSource = function(port: Pointer): CFRunLoopSourceRef; cdecl;
  TIOAllowPowerChange = function(connect: Pointer; token: culong): cint; cdecl;

var
  PMIONotificationPort: Pointer = nil;
  PowerConnect: Pointer = nil;
  IOReg: TLibHandle = NilHandle;
  IORegisterForSystemPower: TIORegisterForSystemPower = nil;
  IONotificationPortGetRunLoopSource: TIONotificationPortGetRunLoopSource = nil;
  IOAllowPowerChange: TIOAllowPowerChange = nil;

procedure InitPowerNegotiation;
begin
  if IOReg <> NilHandle then
    Exit;
  IOReg := LoadLibrary('/System/Library/Frameworks/IOKit.framework/IOKit');
  if IOReg = NilHandle then
    Exit;
  Pointer(IORegisterForSystemPower) := GetProcAddress(IOReg, 'IORegisterForSystemPower');
  Pointer(IONotificationPortGetRunLoopSource) := GetProcAddress(IOReg, 'IONotificationPortGetRunLoopSource');
  Pointer(IOAllowPowerChange) := GetProcAddress(IOReg, 'IOAllowPowerChange');
end;

procedure PowerEventHandler(refcon: Pointer; service: Pointer;
  msgType: cuint32; arg: Pointer); cdecl;
var
  token: culong;
begin
  token := culong(PtrUInt(arg));
  PowerLog('FIRED msg=0x' + IntToHex(msgType, 8));
  if (PowerConnect = nil) or (IOAllowPowerChange = nil) then
  begin
    PowerLog('ABORT: connect/symbols nil');
    Exit;
  end;
  case msgType of
    kIOMessageCanSystemSleep:
    begin
      // Idle sleep: policy is already expressed via the keep-awake assertion.
      IOAllowPowerChange(PowerConnect, token);
      PowerLog('answered CAN-SLEEP allow');
    end;
    kIOMessageSystemWillSleep:
    begin
      // Always cooperate: userspace cannot veto clamshell sleep anyway, and
      // manual sleep (menu / power button) must never be delayed. Drop the
      // assertion for the duration; re-armed on wake while still active.
      OnSystemSleep;
      IOAllowPowerChange(PowerConnect, token);
      PowerLog('answered WILL-SLEEP allow (cooperate)');
    end;
    kIOMessageSystemCapabilityChange:
    begin
      OnSystemWake;      // some wake cycles never deliver HasPoweredOn
      IOAllowPowerChange(PowerConnect, token);
      PowerLog('answered CAPABILITY allow');
    end;
    kIOMessageSystemWillPowerOn:
      OnSystemWake;
    kIOMessageSystemHasPoweredOn:
    begin
      OnSystemWake;      // re-arm the assertion if still active
      PowerLog('powered-on: re-armed');
    end;
  end;
end;

procedure RegisterPowerNotifications;
var
  notifier: Pointer = nil;
  src: CFRunLoopSourceRef;
begin
  if (IORegisterForSystemPower = nil) or (IONotificationPortGetRunLoopSource = nil) then
    Exit;
  PowerConnect := IORegisterForSystemPower(nil, PMIONotificationPort,
    @PowerEventHandler, notifier);
  PowerLog(Format('registered connect=%s port=%s', [
    HexStr(PowerConnect), HexStr(PMIONotificationPort)]));
  if PowerConnect = nil then
    Exit;
  src := IONotificationPortGetRunLoopSource(PMIONotificationPort);
  PowerLog(Format('runloop source=%s', [HexStr(src)]));
  if src <> nil then
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopDefaultMode);
end;

// ---- Menu construction ------------------------------------------------------

procedure TStayAwakeApp.trayAction(sender: id);
begin
  MenuActionInvoke(TMenuAction(NSMenuItem(sender).tag));
end;

// Called by AppKit right before the status-item menu is displayed.
procedure TStayAwakeApp.menuNeedsUpdate(menu: NSMenu);
begin
  SyncMenuStates;
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

// Platform config/hooks must be ready BEFORE the main body starts (the
// shared core reads config paths at any time); wired via the unit's
// initialization section (at the bottom) rather than from TrayCreate.
procedure InitPlatformConfig;
begin
  TrayConfigDir := GetEnvironmentVariable('HOME');
  if TrayConfigDir <> '' then
    TrayConfigDir := TrayConfigDir + '/Library/Application Support';

  // No lid-close blocking on macOS: exhaustively verified that userspace
  // cannot veto clamshell sleep (assertions ignored; IOCancelPowerChange
  // only delays ~5 s; pmset disablesleep would also kill the Sleep menu).
  // See docs/02-design.md for the evidence trail. The menu instead offers
  // "Sleep Now" (`pmset sleepnow`), which works regardless of that setting.
  // The lid submenu IS available on macOS - via the guided one-time admin
  // command (`pmset disablesleep`). Verified exhaustively that this is the
  // only mechanism that blocks clamshell sleep while keeping everything
  // else intact; manual sleep goes through the menu's "Sleep Now".
  TrayHooks.HasLid := True;
  TrayHooks.HasSleepNow := True;

  LidTextTitle[tlEn] := 'Lid Close';                        LidTextTitle[tlZh] := '合盖行为';
  LidTextBlock[tlEn] := 'Stay awake when closed';           LidTextBlock[tlZh] := '保持唤醒(合盖不睡眠)';
  LidTextAllow[tlEn] := 'System default (sleep on close)';  LidTextAllow[tlZh] := '系统默认(合盖睡眠)';

  TrayHooks.RefreshVisual := @HookRefreshVisual;
  TrayHooks.ApplyAwake := @HookApplyAwake;
  TrayHooks.ApplyLidMode := nil;
  TrayHooks.ApplyLanguage := @HookApplyLanguage;
  TrayHooks.ShowAbout := @HookShowAbout;
  TrayHooks.Quit := @HookQuit;
  TrayHooks.SleepNow := @HookSleepNow;
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

  MenuRoot := BuildTrayMenu(TrayHooks.HasLid, TrayHooks.HasSleepNow);
  menu := NSMenu.alloc.initWithTitle(NSString.stringWithUTF8String('StayAwake'));
  FillMenu(menu, MenuRoot);

  StatusItem.setMenu(menu);
  // setDelegate's static type wants NSMenuDelegateProtocol; the informal
  // delegate only needs to respond to menuNeedsUpdate:, so assign via
  // objc_msgSend.
  objc_msgSend_del(menu, sel_getUid('setDelegate:'), AppDelegate);
  menu.release;

  InitPowerNegotiation;
  RegisterPowerNotifications;
  HookRefreshVisual;
  app.run;
end;

initialization
  InitPlatformConfig;

finalization
  FreeTrayMenu(MenuRoot);

end.
