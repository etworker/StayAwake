unit stayawake_tray;

{$MODE objfpc}
{$H+}

interface

procedure TrayCreate;

implementation

uses
  SysUtils,
  Classes,
  stayawake_common,
  ctypes,
  gtk2,
  glib2,
  gdk2,
  gdk2pixbuf,
  gtk2ext;

// Platform renderer for the shared tray core (stayawake_common): it binds the
// declarative menu tree to GtkStatusIcon/GTK2 and implements the platform
// hooks (lid guard service, quit, about). All strings, menu structure, state
// queries and click dispatching live in common and are identical on
// Windows/macOS.

type
  TItemBinding = record
    Node: PMenuNode;
    Widget: PGtkWidget;
    Handler: guint;      // 'toggled'/'activate' handler, blocked during syncs
  end;

var
  StatusIcon: PGtkStatusIcon = nil;
  TrayMenu: PGtkWidget = nil;
  MenuRoot: PMenuNode = nil;
  Bindings: array of TItemBinding;

function MakePixbuf: PGdkPixbuf;
var
  pixels: TIconPixels;
  pb: PGdkPixbuf;
  rstride: cint;
  dst: PByte;
  i: Integer;
begin
  Result := nil;
  GenerateTrayIconPixels(AppActive, pixels);
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

// ---- Platform hooks ---------------------------------------------------------

function HookSystemLang: string; cdecl;
begin
  Result := GetEnvironmentVariable('LANG');
end;

procedure HookApplyAwake; cdecl;
begin
  // Linux keeps the machine awake solely via the periodic mouse nudge while
  // AppActive; nothing to assert or release here.
end;

procedure HookApplyLidMode; cdecl;
begin
  // Best effort: the guard is installed by src/linux/lid-guard/install.sh.
  // If the unit is missing this silently fails and the mode file has no
  // effect until install.sh is run.
  if LidMode = 'block' then
    g_spawn_command_line_async('systemctl --user enable --now ac-lid-guard.service', nil);
end;

procedure HookShowAbout; cdecl;
var
  dlg: PGtkWidget;
begin
  dlg :=
      gtk_message_dialog_new(
          nil,
          0,
          GTK_MESSAGE_INFO,
          GTK_BUTTONS_OK,
          PChar(
              AboutText
                  + #10
                  + 'Linux:合盖行为可按电源状态在托盘菜单中切换。'
          )
      );
  gtk_dialog_run(GTK_DIALOG(dlg));
  gtk_widget_destroy(dlg);
end;

procedure HookQuit; cdecl;
begin
  gtk_main_quit;
end;

// ---- Menu construction and sync ---------------------------------------------

procedure MenuSignalProc(item: PGtkWidget; user_data: gpointer); cdecl;
var
  data: PGInt;
begin
  data := PGInt(g_object_get_data(G_OBJECT(item), 'sa_action'));
  if data <> nil then
    MenuActionInvoke(TMenuAction(PtrUInt(data)));
end;

procedure Bind(Node: PMenuNode; Widget: PGtkWidget; Handler: guint);
var
  n: Integer;
begin
  n := Length(Bindings);
  SetLength(Bindings, n + 1);
  Bindings[n].Node := Node;
  Bindings[n].Widget := Widget;
  Bindings[n].Handler := Handler;
end;

procedure FillMenu(Dest: PGtkWidget; Parent: PMenuNode);
var
  i: Integer;
  node: PMenuNode;
  sub, item: PGtkWidget;
  group: PGSList;
  handler: guint;
  Groups: array of record Id: Integer; List: PGSList; end;
  gi: Integer;
begin
  SetLength(Groups, 0);
  for i := 0 to High(Parent^.Sub) do
  begin
    node := Parent^.Sub[i];
    case node^.Kind of
      mkSep:
        gtk_menu_shell_append(GTK_MENU_SHELL(Dest), gtk_separator_menu_item_new);
      mkSubmenu:
      begin
        sub := gtk_menu_new;
        FillMenu(sub, node);
        item := gtk_menu_item_new_with_label(PChar(L(node^.Text)));
        gtk_menu_item_set_submenu(GTK_MENU_ITEM(item), sub);
        gtk_widget_show_all(sub);
        gtk_menu_shell_append(GTK_MENU_SHELL(Dest), item);
      end;
      mkRadio:
      begin
        group := nil;
        gi := Length(Groups) - 1;
        while gi >= 0 do
        begin
          if Groups[gi].Id = node^.RadioGroup then
          begin
            group := Groups[gi].List;
            Break;
          end;
          Dec(gi);
        end;
        item := gtk_radio_menu_item_new_with_label(group, PChar(L(node^.Text)));
        group := gtk_radio_menu_item_get_group(GTK_RADIO_MENU_ITEM(item));
        if gi >= 0 then
          Groups[gi].List := group
        else begin
          SetLength(Groups, Length(Groups) + 1);
          Groups[High(Groups)].Id := node^.RadioGroup;
          Groups[High(Groups)].List := group;
        end;
        gtk_menu_shell_append(GTK_MENU_SHELL(Dest), item);
        handler := g_signal_connect(item, 'toggled', TGCallback(@MenuSignalProc), nil);
        g_object_set_data(G_OBJECT(item), 'sa_action',
          gpointer(PtrUInt(Ord(node^.Action))));
        Bind(node, item, handler);
      end;
      mkCheck:
      begin
        item := gtk_check_menu_item_new_with_label(PChar(L(node^.Text)));
        gtk_menu_shell_append(GTK_MENU_SHELL(Dest), item);
        handler := g_signal_connect(item, 'toggled', TGCallback(@MenuSignalProc), nil);
        g_object_set_data(G_OBJECT(item), 'sa_action',
          gpointer(PtrUInt(Ord(node^.Action))));
        Bind(node, item, handler);
      end;
      mkItem:
      begin
        item := gtk_menu_item_new_with_label(PChar(L(node^.Text)));
        gtk_menu_shell_append(GTK_MENU_SHELL(Dest), item);
        handler := g_signal_connect(item, 'activate', TGCallback(@MenuSignalProc), nil);
        g_object_set_data(G_OBJECT(item), 'sa_action',
          gpointer(PtrUInt(Ord(node^.Action))));
        Bind(node, item, handler);
      end;
    end;
  end;
  gtk_widget_show_all(Dest);
end;

procedure SyncStates;
var
  i: Integer;
begin
  // gtk_check_menu_item_set_active emits 'toggled', which would re-enter the
  // action dispatcher; block each handler around the programmatic sync.
  for i := 0 to High(Bindings) do
    with Bindings[i] do
      case Node^.Kind of
        mkCheck, mkRadio:
        begin
          g_signal_handler_block(Widget, Handler);
          gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(Widget),
            MenuActionState(Node^.Action));
          g_signal_handler_unblock(Widget, Handler);
        end;
      end;
end;

procedure TraySetVisual;
var
  pb: PGdkPixbuf;
begin
  if StatusIcon = nil then
    Exit;
  pb := MakePixbuf;
  if pb = nil then
    Exit;
  gtk_status_icon_set_from_pixbuf(StatusIcon, pb);
  g_object_unref(pb);
  gtk_status_icon_set_tooltip(StatusIcon, PChar(TrayTooltip));
  SyncStates;
end;

procedure HookApplyLanguage; cdecl;
var
  i: Integer;
begin
  for i := 0 to High(Bindings) do
    SetItemLabel(Bindings[i].Widget, L(Bindings[i].Node^.Text));
  TraySetVisual;
end;

procedure HookRefreshVisual; cdecl;
begin
  TraySetVisual;
end;

procedure ShowMenuAt(status_icon: PGtkStatusIcon; button: guint; activate_time: guint32);
begin
  SyncStates;
  gtk_menu_popup(GTK_MENU(TrayMenu), nil, nil, gtk_status_icon_position_menu, status_icon, button, activate_time);
end;

// Left click opens the same menu as right click: clicking the icon must
// never change behavior silently.
procedure TrayActivateSignal(status_icon: PGtkStatusIcon; user_data: gpointer); cdecl;
begin
  ShowMenuAt(status_icon, 1, gtk_get_current_event_time);
end;

procedure TrayPopupSignal(
    status_icon: PGtkStatusIcon;
    button: guint;
    activate_time: guint32;
    user_data: gpointer
); cdecl;
begin
  ShowMenuAt(status_icon, button, activate_time);
end;

// ---- Entry point ------------------------------------------------------------

procedure TrayCreate;
var
  pb: PGdkPixbuf;
begin
  gtk_init(nil, nil);

  TrayConfigDir := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if TrayConfigDir = '' then
  begin
    TrayConfigDir := GetEnvironmentVariable('HOME');
    if TrayConfigDir <> '' then
      TrayConfigDir := TrayConfigDir + '/.config';
  end;

  TrayHooks.HasLid := True;
  TrayHooks.RefreshVisual := @HookRefreshVisual;
  TrayHooks.ApplyAwake := @HookApplyAwake;
  TrayHooks.ApplyLidMode := @HookApplyLidMode;
  TrayHooks.ApplyLanguage := @HookApplyLanguage;
  TrayHooks.ShowAbout := @HookShowAbout;
  TrayHooks.Quit := @HookQuit;
  TraySystemLang := @HookSystemLang;

  pb := MakePixbuf;
  if pb = nil then
    Exit;
  StatusIcon := gtk_status_icon_new_from_pixbuf(pb);
  g_object_unref(pb);
  gtk_status_icon_set_visible(StatusIcon, TRUE);
  gtk_status_icon_set_tooltip(StatusIcon, 'StayAwake');

  MenuRoot := BuildTrayMenu(TrayHooks.HasLid);
  TrayMenu := gtk_menu_new;
  FillMenu(TrayMenu, MenuRoot);

  // Left click opens the same menu as right click: clicking the icon must
  // never change behavior silently.
  g_signal_connect(StatusIcon, 'activate', TGCallback(@TrayActivateSignal), nil);
  g_signal_connect(StatusIcon, 'popup-menu', TGCallback(@TrayPopupSignal), nil);

  TraySetVisual;
  // Self-heal: if the user opted into "Do Nothing" and the guard service is
  // not running (e.g. fresh login with a stale unit), bring it back up.
  if LidMode = 'block' then
    HookApplyLidMode;
  gtk_main;
end;

finalization
  FreeTrayMenu(MenuRoot);

end.
