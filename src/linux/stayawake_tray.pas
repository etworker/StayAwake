unit stayawake_tray;

{$mode objfpc}{$H+}

interface

procedure TrayCreate;

implementation

uses
  SysUtils,
  Classes,
  stayawake_common,
  stayawake_autostart,
  ctypes,
  gtk2, glib2, gdk2, gdk2pixbuf, gtk2ext;

type
  TTrayLang = (tlEn, tlZh);
  TStrMap = array[TTrayLang] of string;

const
  // All user-visible strings, per language. Menu labels state the action
  // and its consequence so each item is unambiguous.
  SAwake: TStrMap = (
    'Keep Awake (block idle sleep)', '保持清醒(阻止闲置睡眠)');
  SLidTitle: TStrMap = (
    'Lid Close on AC Power', '合盖行为(接电源时)');
  SLidBlock: TStrMap = (
    'Do Nothing (Guard blocks sleep)', '不动作(守卫拦截睡眠)');
  SLidAllow: TStrMap = (
    'Suspend (system default)', '睡眠(系统默认)');
  SAutoStart: TStrMap = (
    'Run at Login', '开机自启');
  SLangTitle: TStrMap = (
    'Language', '语言 / Language');
  SLangAuto: TStrMap = (
    'Follow System', '跟随系统');
  SAbout: TStrMap = (
    'About StayAwake', '关于 StayAwake');
  SQuit: TStrMap = (
    'Quit', '退出');
  STipWork: TStrMap = (
    'StayAwake - preventing sleep', 'StayAwake - 防睡中');
  STipPause: TStrMap = (
    'StayAwake - paused', 'StayAwake - 已暂停');

var
  StatusIcon: PGtkStatusIcon = nil;
  TrayMenu: PGtkWidget = nil;
  TrayAwakeItem: PGtkWidget = nil;
  TrayAutostartItem: PGtkWidget = nil;
  LidMenuItem: PGtkWidget = nil;
  LidGuardItem: PGtkWidget = nil;
  LidSuspendItem: PGtkWidget = nil;
  LangMenuItem: PGtkWidget = nil;
  LangAutoItem: PGtkWidget = nil;
  LangEnItem: PGtkWidget = nil;
  LangZhItem: PGtkWidget = nil;
  AboutItem: PGtkWidget = nil;
  QuitItem: PGtkWidget = nil;
  AwakeHandler: guint = 0;
  AutostartHandler: guint = 0;
  LidGuardHandler: guint = 0;
  LidSuspendHandler: guint = 0;
  LangAutoHandler: guint = 0;
  LangEnHandler: guint = 0;
  LangZhHandler: guint = 0;

function ConfigDir: string;
var
  Env, Home: string;
begin
  Result := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if Result <> '' then
    Exit;
  Home := GetEnvironmentVariable('HOME');
  if Home = '' then
    Exit('');
  Result := Home + '/.config';
end;

function LidModeFile: string;
begin
  Result := ConfigDir + '/stayawake/lid-mode';
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

function CurrentLang: TTrayLang;
var
  Stored, Locale: string;
begin
  Result := tlEn;
  Stored := LowerCase(ReadConfigValue(LangFilePath, ''));
  if Stored = 'zh' then
    Exit(tlZh);
  if Stored = 'en' then
    Exit(tlEn);
  // No explicit choice yet: follow the session locale.
  Locale := LowerCase(GetEnvironmentVariable('LANG'));
  if Pos('zh', Locale) = 1 then
    Result := tlZh;
end;

function L(M: TStrMap): string;
begin
  Result := M[CurrentLang];
end;

procedure RefreshMenu; forward;

function MakePixbuf: PGdkPixbuf;
var
  pixels: TIconPixels;
  pb: PGdkPixbuf;
  rstride: cint;
  dst: PByte;
  i: Integer;
begin
  Result := nil;
  GenerateIconPixels(AppActive, pixels);
  pb := gdk_pixbuf_new(GDK_COLORSPACE_RGB, TRUE, 8, ICON_SIZE, ICON_SIZE);
  if pb = nil then
    Exit;
  rstride := gdk_pixbuf_get_rowstride(pb);
  dst := PByte(gdk_pixbuf_get_pixels(pb));
  for i := 0 to ICON_SIZE - 1 do
    Move(pixels[i * ICON_SIZE * 4], dst[i * rstride], ICON_SIZE * 4);
  Result := pb;
end;

// The FPC 3.2.2 gtk2 bindings lack gtk_menu_item_set_label, so relabel via
// the item's bin child (a GtkLabel for text menu items).
procedure SetItemLabel(item: PGtkWidget; const text: string);
var
  child: PGtkWidget;
begin
  if item = nil then
    Exit;
  child := gtk_bin_get_child(GTK_BIN(item));
  if (child <> nil) and GTK_IS_LABEL(child) then
    gtk_label_set_text(GTK_LABEL(child), PChar(text));
end;

procedure TraySetVisual;
var
  pb: PGdkPixbuf;
  tip: string;
begin
  if StatusIcon = nil then
    Exit;
  pb := MakePixbuf;
  if pb = nil then
    Exit;
  gtk_status_icon_set_from_pixbuf(StatusIcon, pb);
  g_object_unref(pb);
  if AppActive then
    tip := L(STipWork)
  else
    tip := L(STipPause);
  gtk_status_icon_set_tooltip(StatusIcon, PChar(tip));
end;

procedure ShowMenuAt(status_icon: PGtkStatusIcon; button: guint;
  activate_time: guint32);
begin
  RefreshMenu;
  gtk_menu_popup(GTK_MENU(TrayMenu), nil, nil, gtk_status_icon_position_menu,
    status_icon, button, activate_time);
end;

// Left click opens the same menu as right click: clicking the icon must
// never change behavior silently.
procedure TrayActivateSignal(status_icon: PGtkStatusIcon;
  user_data: gpointer); cdecl;
begin
  ShowMenuAt(status_icon, 1, gtk_get_current_event_time);
end;

procedure TrayPopupSignal(status_icon: PGtkStatusIcon; button: guint;
  activate_time: guint32; user_data: gpointer); cdecl;
begin
  ShowMenuAt(status_icon, button, activate_time);
end;

procedure TrayAwakeToggled(item: PGtkCheckMenuItem; user_data: gpointer); cdecl;
begin
  // Checked = prevent idle sleep; unchecked = normal system sleep policy.
  AppActive := gtk_check_menu_item_get_active(item);
  TraySetVisual;
end;

procedure TrayAutostartProc; cdecl;
begin
  if IsAutoStartEnabled then
    DisableAutoStart
  else
    EnableAutoStart;
  // Sync the checkbox immediately instead of waiting for the next popup.
  RefreshMenu;
end;

// ---- Lid close policy (Linux, user-level, no root) -------------------------
// Mode file: ${XDG_CONFIG_HOME:-$HOME/.config}/stayawake/lid-mode
//   block = lid close on AC does nothing; a user-level guard
//           (ac-lid-guard.service) holds a logind inhibitor while the AC
//           adapter is physically present (read from /sys, immune to UPower
//           misdetection).
//   allow = system default (GNOME suspends on lid close).

function ReadLidMode: string;
begin
  // Anything other than an explicit "block" is treated as "allow".
  if ReadConfigValue(LidModeFile, 'allow') = 'block' then
    Result := 'block'
  else
    Result := 'allow';
end;

procedure WriteLidMode(AMode: string);
begin
  WriteConfigValue(LidModeFile, AMode);
end;

procedure EnsureLidGuardRunning;
begin
  // Best effort: the guard is installed by linux/lid-guard/install.sh.
  // If the unit is missing this silently fails and the mode file has no
  // effect until install.sh is run.
  g_spawn_command_line_async(
    'systemctl --user enable --now ac-lid-guard.service', nil);
end;

procedure LidGuardToggled(item: PGtkCheckMenuItem; user_data: gpointer); cdecl;
begin
  if gtk_check_menu_item_get_active(item) then
  begin
    WriteLidMode('block');
    EnsureLidGuardRunning;
  end;
end;

procedure LidSuspendToggled(item: PGtkCheckMenuItem; user_data: gpointer); cdecl;
begin
  if gtk_check_menu_item_get_active(item) then
    WriteLidMode('allow');
end;

// ---- Language --------------------------------------------------------------

procedure SetAllLabels;
begin
  SetItemLabel(TrayAwakeItem, L(SAwake));
  SetItemLabel(LidMenuItem, L(SLidTitle));
  SetItemLabel(LidGuardItem, L(SLidBlock));
  SetItemLabel(LidSuspendItem, L(SLidAllow));
  SetItemLabel(TrayAutostartItem, L(SAutoStart));
  SetItemLabel(LangMenuItem, L(SLangTitle));
  SetItemLabel(LangAutoItem, L(SLangAuto));
  SetItemLabel(LangEnItem, 'English');
  SetItemLabel(LangZhItem, '中文');
  SetItemLabel(AboutItem, L(SAbout));
  SetItemLabel(QuitItem, L(SQuit));
  TraySetVisual;
end;

procedure ApplyLanguage(ALang: string);
begin
  WriteConfigValue(LangFilePath, ALang);
  SetAllLabels;
end;

procedure LangAutoToggled(item: PGtkCheckMenuItem; user_data: gpointer); cdecl;
begin
  if gtk_check_menu_item_get_active(item) then
    ApplyLanguage('');
end;

procedure LangEnToggled(item: PGtkCheckMenuItem; user_data: gpointer); cdecl;
begin
  if gtk_check_menu_item_get_active(item) then
    ApplyLanguage('en');
end;

procedure LangZhToggled(item: PGtkCheckMenuItem; user_data: gpointer); cdecl;
begin
  if gtk_check_menu_item_get_active(item) then
    ApplyLanguage('zh');
end;

procedure ShowAbout; cdecl;
var
  dlg: PGtkWidget;
begin
  dlg := gtk_message_dialog_new(nil, 0, GTK_MESSAGE_INFO, GTK_BUTTONS_OK,
    PChar(APP_NAME + ' ' + APP_VERSION + #10#10 +
          'Prevents idle sleep by moving the mouse every ' +
          IntToStr(INTERVAL_SECS) + ' seconds.' + #10 +
          'Linux: lid-close policy per power state (tray menu).' + #10#10 +
          '防止系统因「闲置」而睡眠 / 熄屏 / 锁屏。' + #10 +
          'Linux:合盖行为可按电源状态在托盘菜单中切换。'));
  gtk_dialog_run(GTK_DIALOG(dlg));
  gtk_widget_destroy(dlg);
end;

procedure TrayQuit; cdecl;
begin
  gtk_main_quit;
end;

procedure RefreshMenu;
var
  Mode, Lang: string;
begin
  if TrayMenu = nil then
    Exit;
  // Single checkable row for keep-awake; block the handler while syncing.
  // gtk_check_menu_item_set_active also emits 'activate', which would
  // re-enter TrayAutostartProc -> RefreshMenu (infinite recursion), so the
  // autostart handler is blocked for the sync as well.
  g_signal_handler_block(TrayAwakeItem, AwakeHandler);
  g_signal_handler_block(TrayAutostartItem, AutostartHandler);
  gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(TrayAwakeItem), AppActive);
  g_signal_handler_unblock(TrayAwakeItem, AwakeHandler);
  gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(TrayAutostartItem),
    IsAutoStartEnabled);
  g_signal_handler_unblock(TrayAutostartItem, AutostartHandler);

  // Sync radios with blocked handlers: gtk_check_menu_item_set_active
  // emits 'toggled', which would re-write the config files.
  Mode := ReadLidMode;
  g_signal_handler_block(LidGuardItem, LidGuardHandler);
  g_signal_handler_block(LidSuspendItem, LidSuspendHandler);
  gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(LidGuardItem),
    Mode = 'block');
  gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(LidSuspendItem),
    Mode <> 'block');
  g_signal_handler_unblock(LidGuardItem, LidGuardHandler);
  g_signal_handler_unblock(LidSuspendItem, LidSuspendHandler);

  Lang := LowerCase(ReadConfigValue(LangFilePath, ''));
  g_signal_handler_block(LangAutoItem, LangAutoHandler);
  g_signal_handler_block(LangEnItem, LangEnHandler);
  g_signal_handler_block(LangZhItem, LangZhHandler);
  gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(LangAutoItem),
    (Lang <> 'en') and (Lang <> 'zh'));
  gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(LangEnItem), Lang = 'en');
  gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(LangZhItem), Lang = 'zh');
  g_signal_handler_unblock(LangAutoItem, LangAutoHandler);
  g_signal_handler_unblock(LangEnItem, LangEnHandler);
  g_signal_handler_unblock(LangZhItem, LangZhHandler);
end;

procedure TrayCreate;
var
  pb: PGdkPixbuf;
  sep1, sep2, sep2b, sep3: PGtkWidget;
  lidSubmenu, langSubmenu: PGtkWidget;
  group: PGSList;
begin
  gtk_init(nil, nil);

  pb := MakePixbuf;
  if pb = nil then
    Exit;
  StatusIcon := gtk_status_icon_new_from_pixbuf(pb);
  g_object_unref(pb);
  gtk_status_icon_set_visible(StatusIcon, TRUE);
  gtk_status_icon_set_tooltip(StatusIcon, 'StayAwake');

  TrayMenu := gtk_menu_new;

  // Keep Awake: a single checkable row. Checked = prevent idle sleep;
  // unchecked = let the system sleep normally.
  TrayAwakeItem := gtk_check_menu_item_new_with_label(PChar(L(SAwake)));
  sep1 := gtk_separator_menu_item_new;

  // Lid close policy (Linux only, user-level guard).
  lidSubmenu := gtk_menu_new;
  LidGuardItem := gtk_radio_menu_item_new_with_label(nil, PChar(L(SLidBlock)));
  group := gtk_radio_menu_item_get_group(GTK_RADIO_MENU_ITEM(LidGuardItem));
  LidSuspendItem := gtk_radio_menu_item_new_with_label(group, PChar(L(SLidAllow)));
  gtk_menu_shell_append(GTK_MENU_SHELL(lidSubmenu), LidGuardItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(lidSubmenu), LidSuspendItem);
  gtk_widget_show_all(lidSubmenu);
  LidMenuItem := gtk_menu_item_new_with_label(PChar(L(SLidTitle)));
  gtk_menu_item_set_submenu(GTK_MENU_ITEM(LidMenuItem), lidSubmenu);

  TrayAutostartItem := gtk_check_menu_item_new_with_label(PChar(L(SAutoStart)));
  sep2b := gtk_separator_menu_item_new;

  // Language switcher (persisted, applies immediately).
  langSubmenu := gtk_menu_new;
  LangAutoItem := gtk_radio_menu_item_new_with_label(nil, PChar(L(SLangAuto)));
  group := gtk_radio_menu_item_get_group(GTK_RADIO_MENU_ITEM(LangAutoItem));
  LangEnItem := gtk_radio_menu_item_new_with_label(group, 'English');
  LangZhItem := gtk_radio_menu_item_new_with_label(group, PChar('中文'));
  gtk_menu_shell_append(GTK_MENU_SHELL(langSubmenu), LangAutoItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(langSubmenu), LangEnItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(langSubmenu), LangZhItem);
  gtk_widget_show_all(langSubmenu);
  LangMenuItem := gtk_menu_item_new_with_label(PChar(L(SLangTitle)));
  gtk_menu_item_set_submenu(GTK_MENU_ITEM(LangMenuItem), langSubmenu);

  sep2 := gtk_separator_menu_item_new;
  AboutItem := gtk_menu_item_new_with_label(PChar(L(SAbout)));
  sep3 := gtk_separator_menu_item_new;
  QuitItem := gtk_menu_item_new_with_label(PChar(L(SQuit)));

  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), TrayAwakeItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), sep1);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), LidMenuItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), TrayAutostartItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), sep2b);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), LangMenuItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), sep2);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), AboutItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), sep3);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), QuitItem);
  gtk_widget_show_all(TrayMenu);

  // Left click opens the same menu as right click: clicking the icon must
  // never change behavior silently.
  g_signal_connect(StatusIcon, 'activate', TGCallback(@TrayActivateSignal), nil);
  g_signal_connect(StatusIcon, 'popup-menu', TGCallback(@TrayPopupSignal), nil);
  AwakeHandler := g_signal_connect(TrayAwakeItem, 'toggled',
    TGCallback(@TrayAwakeToggled), nil);
  AutostartHandler := g_signal_connect(TrayAutostartItem, 'activate', TGCallback(@TrayAutostartProc), nil);
  LidGuardHandler := g_signal_connect(LidGuardItem, 'toggled',
    TGCallback(@LidGuardToggled), nil);
  LidSuspendHandler := g_signal_connect(LidSuspendItem, 'toggled',
    TGCallback(@LidSuspendToggled), nil);
  LangAutoHandler := g_signal_connect(LangAutoItem, 'toggled',
    TGCallback(@LangAutoToggled), nil);
  LangEnHandler := g_signal_connect(LangEnItem, 'toggled',
    TGCallback(@LangEnToggled), nil);
  LangZhHandler := g_signal_connect(LangZhItem, 'toggled',
    TGCallback(@LangZhToggled), nil);
  g_signal_connect(AboutItem, 'activate', TGCallback(@ShowAbout), nil);
  g_signal_connect(QuitItem, 'activate', TGCallback(@TrayQuit), nil);

  RefreshMenu;
  SetAllLabels; // default language follows locale until the user picks one
  // Self-heal: if the user opted into "Do Nothing" and the guard service is
  // not running (e.g. fresh login with a stale unit), bring it back up.
  if ReadLidMode = 'block' then
    EnsureLidGuardRunning;
  gtk_main;
end;

end.
