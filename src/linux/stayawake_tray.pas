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

var
  StatusIcon: PGtkStatusIcon = nil;
  TrayMenu: PGtkWidget = nil;
  TrayStartItem: PGtkWidget = nil;
  TrayStopItem: PGtkWidget = nil;
  TrayAutostartItem: PGtkWidget = nil;
  LidMenuItem: PGtkWidget = nil;
  LidGuardItem: PGtkWidget = nil;
  LidSuspendItem: PGtkWidget = nil;
  LidGuardHandler: guint = 0;
  LidSuspendHandler: guint = 0;

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
    tip := 'StayAwake - Working'
  else
    tip := 'StayAwake - Paused';
  gtk_status_icon_set_tooltip(StatusIcon, PChar(tip));
end;

procedure TrayToggle; cdecl;
begin
  AppActive := not AppActive;
  TraySetVisual;
end;

procedure ShowAbout; cdecl;
var
  dlg: PGtkWidget;
begin
  dlg := gtk_message_dialog_new(nil, 0, GTK_MESSAGE_INFO, GTK_BUTTONS_OK,
    PChar(APP_NAME + ' ' + APP_VERSION + #10 + #10 +
          'Prevents the system from sleeping by moving the mouse every ' +
          IntToStr(INTERVAL_SECS) + ' seconds.'));
  gtk_dialog_run(GTK_DIALOG(dlg));
  gtk_widget_destroy(dlg);
end;

procedure TrayStartProc; cdecl;
begin
  if not AppActive then
  begin
    AppActive := True;
    TraySetVisual;
  end;
end;

procedure TrayStopProc; cdecl;
begin
  if AppActive then
  begin
    AppActive := False;
    TraySetVisual;
  end;
end;

procedure TrayAutostartProc; cdecl;
begin
  if IsAutoStartEnabled then
    DisableAutoStart
  else
    EnableAutoStart;
end;

// ---- Lid close policy (Linux, user-level, no root) -------------------------
// Mode file: ${XDG_CONFIG_HOME:-$HOME/.config}/stayawake/lid-mode
//   block = lid close on AC does nothing; a user-level guard
//           (ac-lid-guard.service) holds a logind inhibitor while the AC
//           adapter is physically present (read from /sys, immune to UPower
//           misdetection).
//   allow = system default (GNOME suspends on lid close).

function LidModeFile: string;
var
  ConfigDir, Home: string;
begin
  ConfigDir := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if ConfigDir = '' then
  begin
    Home := GetEnvironmentVariable('HOME');
    if Home = '' then
      Exit('');
    ConfigDir := Home + '/.config';
  end;
  Result := ConfigDir + '/stayawake/lid-mode';
end;

function ReadLidMode: string;
var
  sl: TStringList;
begin
  Result := 'allow'; // system default: suspend on lid close
  if (LidModeFile = '') or (not FileExists(LidModeFile)) then
    Exit;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(LidModeFile);
      if (sl.Count > 0) and (Trim(sl[0]) = 'block') then
        Result := 'block';
    except
      on E: Exception do
        ;
    end;
  finally
    sl.Free;
  end;
end;

procedure WriteLidMode(AMode: string);
var
  Path: string;
  sl: TStringList;
begin
  Path := LidModeFile;
  if Path = '' then
    Exit;
  if not ForceDirectories(ExtractFilePath(Path)) then
    Exit;
  sl := TStringList.Create;
  try
    sl.Add(AMode);
    try
      sl.SaveToFile(Path);
    except
      // Must not crash the tray if the config dir is unwritable; the lid
      // policy simply stays unchanged.
      on E: Exception do
        ;
    end;
  finally
    sl.Free;
  end;
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

procedure TrayQuit; cdecl;
begin
  gtk_main_quit;
end;

procedure RefreshMenu;
var
  Mode: string;
begin
  if TrayMenu = nil then
    Exit;
  gtk_widget_set_sensitive(TrayStartItem, not AppActive);
  gtk_widget_set_sensitive(TrayStopItem, AppActive);
  gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(TrayAutostartItem),
    IsAutoStartEnabled);
  Mode := ReadLidMode;
  // Block the toggled handlers while syncing: gtk_check_menu_item_set_active
  // emits 'toggled', which would re-write the mode file.
  g_signal_handler_block(LidGuardItem, LidGuardHandler);
  g_signal_handler_block(LidSuspendItem, LidSuspendHandler);
  gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(LidGuardItem),
    Mode = 'block');
  gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(LidSuspendItem),
    Mode <> 'block');
  g_signal_handler_unblock(LidGuardItem, LidGuardHandler);
  g_signal_handler_unblock(LidSuspendItem, LidSuspendHandler);
end;

procedure TrayPopupSignal(status_icon: PGtkStatusIcon; button: guint;
  activate_time: guint32; user_data: gpointer); cdecl;
begin
  RefreshMenu;
  gtk_menu_popup(GTK_MENU(TrayMenu), nil, nil, gtk_status_icon_position_menu,
    status_icon, button, activate_time);
end;

procedure TrayCreate;
var
  pb: PGdkPixbuf;
  sep1, sep2, sep2b, sep3: PGtkWidget;
  aboutItem, quitItem: PGtkWidget;
  lidSubmenu: PGtkWidget;
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
  TrayStartItem := gtk_menu_item_new_with_label('Start Awake');
  TrayStopItem := gtk_menu_item_new_with_label('Stop Awake');
  sep1 := gtk_separator_menu_item_new;
  TrayAutostartItem := gtk_check_menu_item_new_with_label('Start on Login');
  sep2b := gtk_separator_menu_item_new;
  lidSubmenu := gtk_menu_new;
  LidGuardItem := gtk_radio_menu_item_new_with_label(nil, 'Do Nothing (Guard)');
  group := gtk_radio_menu_item_get_group(GTK_RADIO_MENU_ITEM(LidGuardItem));
  LidSuspendItem := gtk_radio_menu_item_new_with_label(group, 'Suspend');
  gtk_menu_shell_append(GTK_MENU_SHELL(lidSubmenu), LidGuardItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(lidSubmenu), LidSuspendItem);
  gtk_widget_show_all(lidSubmenu);
  LidMenuItem := gtk_menu_item_new_with_label('Lid Close on AC');
  gtk_menu_item_set_submenu(GTK_MENU_ITEM(LidMenuItem), lidSubmenu);
  sep2 := gtk_separator_menu_item_new;
  aboutItem := gtk_menu_item_new_with_label('About...');
  sep3 := gtk_separator_menu_item_new;
  quitItem := gtk_menu_item_new_with_label('Quit');
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), TrayStartItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), TrayStopItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), sep1);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), TrayAutostartItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), sep2b);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), LidMenuItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), sep2);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), aboutItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), sep3);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), quitItem);
  gtk_widget_show_all(TrayMenu);

  g_signal_connect(StatusIcon, 'activate', TGCallback(@TrayToggle), nil);
  g_signal_connect(StatusIcon, 'popup-menu', TGCallback(@TrayPopupSignal), nil);
  g_signal_connect(TrayStartItem, 'activate', TGCallback(@TrayStartProc), nil);
  g_signal_connect(TrayStopItem, 'activate', TGCallback(@TrayStopProc), nil);
  g_signal_connect(TrayAutostartItem, 'activate', TGCallback(@TrayAutostartProc), nil);
  LidGuardHandler := g_signal_connect(LidGuardItem, 'toggled',
    TGCallback(@LidGuardToggled), nil);
  LidSuspendHandler := g_signal_connect(LidSuspendItem, 'toggled',
    TGCallback(@LidSuspendToggled), nil);
  g_signal_connect(aboutItem, 'activate', TGCallback(@ShowAbout), nil);
  g_signal_connect(quitItem, 'activate', TGCallback(@TrayQuit), nil);

  RefreshMenu;
  // Self-heal: if the user opted into "Do Nothing" and the guard service is
  // not running (e.g. fresh login with a stale unit), bring it back up.
  if ReadLidMode = 'block' then
    EnsureLidGuardRunning;
  gtk_main;
end;

end.