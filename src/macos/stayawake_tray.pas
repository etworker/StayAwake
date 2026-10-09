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
  stayawake_autostart,
  stayawake_mover,
  CocoaAll,
  MacOSAll;

// Menu structure and behavior mirror the Linux tray (src/linux/stayawake_tray.pas):
// single checkable "Keep Awake" row, localized labels (EN/中文) with an in-menu
// language switcher, and any click on the status item opening the same menu.
// The Linux-only lid-close submenu has no macOS counterpart (logind guard) and
// is absent, exactly as on Windows. Keep the SAwake/SAutoStart/... string
// tables 1:1 across all three tray units.

type
  TStayAwakeApp = objcclass(NSObject)
  public
    procedure toggleAwake(sender: id); message 'toggleAwake:';
    procedure toggleAutostart(sender: id); message 'toggleAutostart:';
    procedure langAuto(sender: id); message 'langAuto:';
    procedure langEn(sender: id); message 'langEn:';
    procedure langZh(sender: id); message 'langZh:';
    procedure showAbout(sender: id); message 'showAbout:';
    procedure quitApp(sender: id); message 'quitApp:';
  end;

type
  TTrayLang = (tlEn, tlZh);
  TStrMap = array[TTrayLang] of string;

const
  // All user-visible strings, per language. Menu labels state the action
  // and its consequence so each item is unambiguous. Keep 1:1 with Linux/Win.
  SAwake: TStrMap = ('Keep Awake (block idle sleep)', '保持清醒(阻止闲置睡眠)');
  SAutoStart: TStrMap = ('Run at Login', '开机自启');
  SLangTitle: TStrMap = ('Language', '语言 / Language');
  SLangAuto: TStrMap = ('Follow System', '跟随系统');
  SAbout: TStrMap = ('About StayAwake', '关于 StayAwake');
  SQuit: TStrMap = ('Quit', '退出');
  STipWork: TStrMap = ('StayAwake - preventing sleep', 'StayAwake - 防睡中');
  STipPause: TStrMap = ('StayAwake - paused', 'StayAwake - 已暂停');

var
  StatusItem: NSStatusItem = nil;
  MenuAwake: NSMenuItem = nil;
  MenuAutostart: NSMenuItem = nil;
  MenuLang: NSMenuItem = nil;
  LangAutoItem: NSMenuItem = nil;
  LangEnItem: NSMenuItem = nil;
  LangZhItem: NSMenuItem = nil;
  AboutItem: NSMenuItem = nil;
  QuitItem: NSMenuItem = nil;
  AppDelegate: TStayAwakeApp = nil;

// ---- Config (language choice), mirrors the Linux tray ----------------------

function ConfigDir: string;
var
  Home: string;
begin
  Home := GetEnvironmentVariable('HOME');
  if Home = '' then
    Exit('');
  Result := Home + '/Library/Application Support';
end;

function LangFilePath: string;
begin
  Result := ConfigDir + '/stayawake/lang';
end;

function ReadConfigValue(FileName, DefValue: string): string;
var
  sl: TStringList;
begin
  Result := DefValue;
  if (FileName = '') or (not FileExists(FileName)) then
    Exit;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(FileName);
      if sl.Count > 0 then
        Result := Trim(sl[0]);
    except
      on E: Exception do
        ;
    end;
  finally
    sl.Free;
  end;
end;

procedure WriteConfigValue(FileName, Value: string);
var
  sl: TStringList;
begin
  if FileName = '' then
    Exit;
  if not ForceDirectories(ExtractFilePath(FileName)) then
    Exit;
  sl := TStringList.Create;
  try
    sl.Add(Value);
    try
      sl.SaveToFile(FileName);
    except
      // Config must not crash the tray; the setting stays unchanged.
      on E: Exception do
        ;
    end;
  finally
    sl.Free;
  end;
end;

function CurrentLangStored: string;
begin
  Result := LowerCase(ReadConfigValue(LangFilePath, ''));
end;

function SystemLangCode: string;
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

function CurrentLang: TTrayLang;
var
  Stored: string;
begin
  Result := tlEn;
  Stored := CurrentLangStored;
  if Stored = 'zh' then
    Exit(tlZh);
  if Stored = 'en' then
    Exit(tlEn);
  // No explicit choice yet: follow the system UI language (zh-* -> Chinese).
  if Pos('zh', SystemLangCode) = 1 then
    Result := tlZh;
end;

function L(M: TStrMap): string;
begin
  Result := M[CurrentLang];
end;

// ---- Tray visuals -----------------------------------------------------------

procedure TraySetVisual; forward;

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
  GenerateTrayIconPixels(AppActive, pixels);
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

procedure SetCheckState(item: NSMenuItem; checked: Boolean);
begin
  if item = nil then
    Exit;
  if checked then
    item.setState(NSOnState)
  else
    item.setState(NSOffState);
end;

procedure TraySetVisual;
var
  img: NSImage;
  Stored: string;
begin
  if StatusItem = nil then
    Exit;
  img := MakeStatusImage;
  if img <> nil then
  begin
    StatusItem.setImage(img);
    img.release;
  end;
  if AppActive then
    StatusItem.setToolTip(NSString.stringWithUTF8String(PChar(L(STipWork))))
  else
    StatusItem.setToolTip(NSString.stringWithUTF8String(PChar(L(STipPause))));
  // Checkable Keep Awake row and the autostart switch reflect live state;
  // setState does not fire actions, so no handler blocking is needed.
  SetCheckState(MenuAwake, AppActive);
  SetCheckState(MenuAutostart, IsAutoStartEnabled);
  // Language radio group (managed manually; auto-enables is off).
  Stored := CurrentLangStored;
  SetCheckState(LangAutoItem, (Stored <> 'en') and (Stored <> 'zh'));
  SetCheckState(LangEnItem, Stored = 'en');
  SetCheckState(LangZhItem, Stored = 'zh');
end;

// ---- Language ---------------------------------------------------------------

procedure UpdateAllTitles;
begin
  if StatusItem = nil then
    Exit;
  MenuAwake.setTitle(NSString.stringWithUTF8String(PChar(L(SAwake))));
  MenuAutostart.setTitle(NSString.stringWithUTF8String(PChar(L(SAutoStart))));
  MenuLang.setTitle(NSString.stringWithUTF8String(PChar(L(SLangTitle))));
  LangAutoItem.setTitle(NSString.stringWithUTF8String(PChar(L(SLangAuto))));
  AboutItem.setTitle(NSString.stringWithUTF8String(PChar(L(SAbout))));
  QuitItem.setTitle(NSString.stringWithUTF8String(PChar(L(SQuit))));
  TraySetVisual;
end;

procedure ApplyLanguage(ALang: string);
begin
  WriteConfigValue(LangFilePath, ALang);
  UpdateAllTitles;
end;

// ---- Actions ----------------------------------------------------------------

procedure TStayAwakeApp.toggleAwake(sender: id);
begin
  // Checked = prevent idle sleep; unchecked = normal system sleep policy.
  AppActive := not AppActive;
  UpdateExecutionState;
  TraySetVisual;
end;

procedure TStayAwakeApp.toggleAutostart(sender: id);
begin
  if IsAutoStartEnabled then
    DisableAutoStart
  else
    EnsureAutoStart;
  // Sync the checkbox immediately instead of waiting for the next sync.
  TraySetVisual;
end;

procedure TStayAwakeApp.langAuto(sender: id);
begin
  ApplyLanguage('');
end;

procedure TStayAwakeApp.langEn(sender: id);
begin
  ApplyLanguage('en');
end;

procedure TStayAwakeApp.langZh(sender: id);
begin
  ApplyLanguage('zh');
end;

procedure TStayAwakeApp.showAbout(sender: id);
var
  alert: NSAlert;
  info: string;
begin
  alert := NSAlert.alloc.init;
  alert.setMessageText(NSString.stringWithUTF8String(PChar(L(SAbout))));
  info :=
      APP_NAME + ' ' + APP_VERSION + #10#10 +
      'Prevents idle sleep by moving the mouse every ' +
      IntToStr(INTERVAL_SECS) + ' seconds.' + #10#10 +
      '防止系统因「闲置」而睡眠 / 熄屏 / 锁屏。';
  alert.setInformativeText(NSString.stringWithUTF8String(PChar(info)));
  alert.addButtonWithTitle(NSString.stringWithUTF8String('OK'));
  alert.runModal;
  alert.release;
end;

procedure TStayAwakeApp.quitApp(sender: id);
begin
  NSApplication(NSApp).terminate(nil);
end;

// ---- Construction -----------------------------------------------------------

function NewMenuItem(const title: string; sel: SEL): NSMenuItem;
begin
  Result := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSString.stringWithUTF8String(PChar(title)), sel, NSString.stringWithUTF8String(''));
  Result.setTarget(AppDelegate);
end;

procedure TrayCreate;
var
  app: NSApplication;
  menu, langSub: NSMenu;
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

  // Keep Awake: a single checkable row. Checked = prevent idle sleep;
  // unchecked = let the system sleep normally.
  MenuAwake := NewMenuItem(L(SAwake), objcselector('toggleAwake:'));

  MenuAutostart := NewMenuItem(L(SAutoStart), objcselector('toggleAutostart:'));

  // Language switcher (persisted, applies immediately).
  langSub := NSMenu.alloc.initWithTitle(NSString.stringWithUTF8String('Language'));
  langSub.setAutoenablesItems(False);
  LangAutoItem := NewMenuItem(L(SLangAuto), objcselector('langAuto:'));
  LangEnItem := NewMenuItem('English', objcselector('langEn:'));
  LangZhItem := NewMenuItem('中文', objcselector('langZh:'));
  langSub.addItem(LangAutoItem);
  langSub.addItem(LangEnItem);
  langSub.addItem(LangZhItem);
  MenuLang := NewMenuItem(L(SLangTitle), nil);
  MenuLang.setSubmenu(langSub);
  langSub.release;

  AboutItem := NewMenuItem(L(SAbout), objcselector('showAbout:'));
  QuitItem := NewMenuItem(L(SQuit), objcselector('quitApp:'));

  menu.addItem(MenuAwake);
  menu.addItem(NSMenuItem.separatorItem);
  menu.addItem(MenuAutostart);
  menu.addItem(NSMenuItem.separatorItem);
  menu.addItem(MenuLang);
  menu.addItem(NSMenuItem.separatorItem);
  menu.addItem(AboutItem);
  menu.addItem(NSMenuItem.separatorItem);
  menu.addItem(QuitItem);

  StatusItem.setMenu(menu);
  // The menu (owned by the status item) holds the item references; only the
  // outer allocations need balancing here.
  menu.release;
  MenuAwake.release;
  MenuAutostart.release;
  MenuLang.release;
  LangAutoItem.release;
  LangEnItem.release;
  LangZhItem.release;
  AboutItem.release;
  QuitItem.release;

  TraySetVisual;
  app.run;
end;

end.
