unit stayawake_tray;

{$mode objfpc}{$H+}

interface

procedure TrayCreate;

implementation

uses
  SysUtils,
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
    EnsureAutoStart;
end;

procedure TrayQuit; cdecl;
begin
  gtk_main_quit;
end;

procedure RefreshMenu;
begin
  if TrayMenu = nil then
    Exit;
  gtk_widget_set_sensitive(TrayStartItem, not AppActive);
  gtk_widget_set_sensitive(TrayStopItem, AppActive);
  gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(TrayAutostartItem),
    IsAutoStartEnabled);
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
  sep: PGtkWidget;
  aboutItem, quitItem: PGtkWidget;
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
  sep := gtk_separator_menu_item_new;
  TrayAutostartItem := gtk_check_menu_item_new_with_label('Start on Login');
  sep := gtk_separator_menu_item_new;
  aboutItem := gtk_menu_item_new_with_label('About...');
  sep := gtk_separator_menu_item_new;
  quitItem := gtk_menu_item_new_with_label('Quit');
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), TrayStartItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), TrayStopItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), sep);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), TrayAutostartItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), sep);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), aboutItem);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), sep);
  gtk_menu_shell_append(GTK_MENU_SHELL(TrayMenu), quitItem);
  gtk_widget_show_all(TrayMenu);

  g_signal_connect(StatusIcon, 'activate', TGCallback(@TrayToggle), nil);
  g_signal_connect(StatusIcon, 'popup-menu', TGCallback(@TrayPopupSignal), nil);
  g_signal_connect(TrayStartItem, 'activate', TGCallback(@TrayStartProc), nil);
  g_signal_connect(TrayStopItem, 'activate', TGCallback(@TrayStopProc), nil);
  g_signal_connect(TrayAutostartItem, 'activate', TGCallback(@TrayAutostartProc), nil);
  g_signal_connect(aboutItem, 'activate', TGCallback(@ShowAbout), nil);
  g_signal_connect(quitItem, 'activate', TGCallback(@TrayQuit), nil);

  RefreshMenu;
  gtk_main;
end;

end.