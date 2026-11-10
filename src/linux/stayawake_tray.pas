unit stayawake_tray;

{$MODE objfpc}
{$H+}

interface

procedure TrayCreate;

implementation

uses
  SysUtils,
  Classes,
  BaseUnix,
  dynlibs,
  stayawake_common,
  stayawake_mover,
  stayawake_autostart,
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
    Handler: guint; // 'toggled'/'activate' handler, blocked during syncs
  end;

var
  StatusIcon: PGtkStatusIcon = nil;
  TrayMenu: PGtkWidget = nil;
  MenuRoot: PMenuNode = nil;
  Bindings: array of TItemBinding;

function MakePixbufSized(Size: Integer): PGdkPixbuf; forward;

function MakePixbuf: PGdkPixbuf;
begin
  Result := MakePixbufSized(ICON_SIZE);
end;

// Sized variant (e.g. 96 px for the About dialog image).
function MakePixbufSized(Size: Integer): PGdkPixbuf;
var
  pixels: array of Byte;
  pb: PGdkPixbuf;
  rstride: cint;
  dst: PByte;
  i: Integer;
begin
  Result := nil;
  SetLength(pixels, Size * Size * 4);
  GenerateIconPixels(Size, AppActive, @pixels[0]);
  pb := gdk_pixbuf_new(GDK_COLORSPACE_RGB, TRUE, 8, Size, Size);
  if pb = nil then
    Exit;
  rstride := gdk_pixbuf_get_rowstride(pb);
  dst := PByte(gdk_pixbuf_get_pixels(pb));
  for i := 0 to Size - 1 do
    Move(pixels[i * Size * 4], dst[i * rstride], Size * 4);
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

procedure WriteTextFile(const path, content: string);
var
  sl: TStringList;
begin
  ForceDirectories(ExtractFilePath(path));
  sl := TStringList.Create;
  try
    sl.Text := content;
    sl.SaveToFile(path);
  finally
    sl.Free;
  end;
end;

procedure ChmodFile(const path: string; mode: Integer);
begin
  FpChmod(PAnsiChar(path), mode);
end;

// The guard component (service unit + guard script) is embedded below and
// self-installed into the user's systemd session the first time "block"
// mode is picked - no terminal, no root, nothing to download.

const
  GUARD_UNIT: string =
      '[Unit]'
          + LineEnding
          + 'Description=StayAwake lid guard (lid close on AC does nothing)'
          + LineEnding
          + 'PartOf=graphical-session.target'
          + LineEnding
          + 'After=graphical-session.target'
          + LineEnding
          + ''
          + LineEnding
          + '[Service]'
          + LineEnding
          + 'Type=simple'
          + LineEnding
          + 'ExecStart=%h/.local/bin/ac-lid-guard.sh'
          + LineEnding
          + 'Restart=always'
          + LineEnding
          + 'RestartSec=3'
          + LineEnding
          + ''
          + LineEnding
          + '[Install]'
          + LineEnding
          + 'WantedBy=default.target'
          + LineEnding;

  GUARD_SH: string =
      '#!/bin/bash'
          + LineEnding
          + '# StayAwake lid guard (user-level, no sudo required).'
          + LineEnding
          + '#'
          + LineEnding
          + '# Holds logind inhibitors so that the per-power-source lid policy chosen in'
          + LineEnding
          + '# the tray takes effect (the kernel''s own lid handling must not fire first):'
          + LineEnding
          + '#   on AC,      lid-ac=awake (default) -> sleep:handle-lid-switch inhibitor:'
          + LineEnding
          + '#       closing the lid does nothing, and idle sleep is held too (headless'
          + LineEnding
          + '#       use of a closed lid on power keeps working as it always has)'
          + LineEnding
          + '#   on battery, lid-ac=awake AND lid-battery-mins != 0 -> handle-lid-switch'
          + LineEnding
          + '#       inhibitor only: the close event itself is blocked while a timer'
          + LineEnding
          + '#       window can run, but idle sleep is NOT held (sleeping earlier than'
          + LineEnding
          + '#       the timer is allowed, same as macOS) and the app''s `systemctl'
          + LineEnding
          + '#       suspend` is not blocked by our own inhibitor. The lid-ac gate'
          + LineEnding
          + '#       mirrors the engine: the awake-on-power checkbox is the master'
          + LineEnding
          + '#       switch for the whole lid policy.'
          + LineEnding
          + '# Any other combination -> no inhibitor, system default behavior.'
          + LineEnding
          + '#'
          + LineEnding
          + '# Config dir: ${XDG_CONFIG_HOME:-$HOME/.config}/stayawake'
          + LineEnding
          + '#   lid-ac            awake|default (missing = awake)'
          + LineEnding
          + '#   lid-battery-mins  0|1|5|15|30|60|-1 (missing = 0: sleep on close)'
          + LineEnding
          + '# The guard re-reads both files every cycle, so the tray can change the'
          + LineEnding
          + '# policy without restarting anything. Reading the adapter state from /sys'
          + LineEnding
          + '# (kernel) instead of UPower makes this immune to UPower AC misdetection'
          + LineEnding
          + '# bugs.'
          + LineEnding
          + ''
          + LineEnding
          + 'CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/stayawake"'
          + LineEnding
          + ''
          + LineEnding
          + 'ac_online() { grep -q "^1$" /sys/class/power_supply/A*/online 2>/dev/null; }'
          + LineEnding
          + ''
          + LineEnding
          + '# What should be inhibited right now: "both" (on AC, awake on close),'
          + LineEnding
          + '# "lid" (on battery, policy on and a timer or never mode is armed), or "none".'
          + LineEnding
          + 'desired() {'
          + LineEnding
          + '  if ac_online; then'
          + LineEnding
          + '    if [ "$(cat "$CONF_DIR/lid-ac" 2>/dev/null || echo awake)" = "awake" ]; then'
          + LineEnding
          + '      echo both'
          + LineEnding
          + '      return'
          + LineEnding
          + '    fi'
          + LineEnding
          + '  elif [ "$(cat "$CONF_DIR/lid-ac" 2>/dev/null || echo awake)" = "awake" ] \'
          + LineEnding
          + '       && [ "$(cat "$CONF_DIR/lid-battery-mins" 2>/dev/null || echo 0)" != "0" ]; then'
          + LineEnding
          + '    echo lid'
          + LineEnding
          + '    return'
          + LineEnding
          + '  fi'
          + LineEnding
          + '  echo none'
          + LineEnding
          + '}'
          + LineEnding
          + ''
          + LineEnding
          + 'while :; do'
          + LineEnding
          + '  case "$(desired)" in'
          + LineEnding
          + '    both)'
          + LineEnding
          + '      systemd-inhibit --what=sleep:handle-lid-switch --who="StayAwake lid-guard" \'
          + LineEnding
          + '        --why="AC lid close = do nothing (user choice)" \'
          + LineEnding
          + '        bash -c ''CONF="${XDG_CONFIG_HOME:-$HOME/.config}/stayawake"; while [ "$(cat "$CONF/lid-ac" 2>/dev/null || echo awake)" = "awake" ] && grep -q "^1$" /sys/class/power_supply/A*/online 2>/dev/null; do sleep 3; done'''
          + LineEnding
          + '      ;;'
          + LineEnding
          + '    lid)'
          + LineEnding
          + '      systemd-inhibit --what=handle-lid-switch --who="StayAwake lid-guard" \'
          + LineEnding
          + '        --why="battery lid timer armed" \'
          + LineEnding
          + '        bash -c ''CONF="${XDG_CONFIG_HOME:-$HOME/.config}/stayawake"; while [ "$(cat "$CONF/lid-ac" 2>/dev/null || echo awake)" = "awake" ] && [ "$(cat "$CONF/lid-battery-mins" 2>/dev/null || echo 0)" != "0" ] && ! grep -q "^1$" /sys/class/power_supply/A*/online 2>/dev/null; do sleep 3; done'''
          + LineEnding
          + '      ;;'
          + LineEnding
          + '    *)'
          + LineEnding
          + '      sleep 3'
          + LineEnding
          + '      ;;'
          + LineEnding
          + '  esac'
          + LineEnding
          + 'done'
          + LineEnding;

function TextFileDiffers(const path, content: string): Boolean;
var
  sl: TStringList;
begin
  Result := True;
  if not FileExists(path) then
    Exit;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(path);
      Result := sl.Text <> content;
    except
      Result := True; // unreadable: rewrite it
    end;
  finally
    sl.Free;
  end;
end;

procedure EnsureLidGuardInstalled;
var
  Home, UnitPath, ScriptPath: string;
  changed: Boolean;
begin
  Home := GetEnvironmentVariable('HOME');
  if Home = '' then
    Exit;
  UnitPath := Home + '/.config/systemd/user/ac-lid-guard.service';
  ScriptPath := Home + '/.local/bin/ac-lid-guard.sh';
  // Rewrite whenever the embedded copy differs from what is installed: this
  // upgrades older installs (which shipped the lid-mode-based script) in
  // place, without touching the user's config choices.
  changed := False;
  if TextFileDiffers(ScriptPath, GUARD_SH) then begin
    WriteTextFile(ScriptPath, GUARD_SH);
    FpChmod(PAnsiChar(ScriptPath), &755);
    changed := True;
  end;
  if TextFileDiffers(UnitPath, GUARD_UNIT) then begin
    WriteTextFile(UnitPath, GUARD_UNIT);
    FpChmod(PAnsiChar(UnitPath), &644);
    changed := True;
  end;
  if changed then
    g_spawn_command_line_async('systemctl --user daemon-reload', nil);
end;

procedure HookSleepNow; cdecl;
begin
  // systemd-logind lets an active local session suspend without a password
  // (standard polkit rule); this is the same call desktop power menus make.
  g_spawn_command_line_async('systemctl suspend', nil);
end;

procedure HookApplyLidMode; cdecl;
begin
  // The guard re-reads the config files every cycle, so a policy change
  // needs no re-arm; this hook only makes sure the component is installed
  // and running. Idempotent: safe to call on every lid option change and on
  // every startup with a lid.
  EnsureLidGuardInstalled;
  g_spawn_command_line_async('systemctl --user enable --now ac-lid-guard.service', nil);
end;

procedure HookSleepNow; cdecl;
begin
  // Rootless on systemd; the same execution path the lid policy uses.
  SystemSuspend;
end;

procedure HookShowAbout; cdecl;
var
  dlg: PGtkWidget;
  pb: PGdkPixbuf;
begin
  dlg :=
      gtk_message_dialog_new(
          nil,
          0,
          GTK_MESSAGE_INFO,
          GTK_BUTTONS_OK,
          PChar(AboutText + #10 + 'Linux:合盖行为可按电源状态在托盘菜单中切换。')
      );
  // Replace the generic info icon with the app eye (same artwork as tray).
  // FPC 3.2.2 bindings lack gtk_message_dialog_set_image; the "image"
  // GObject property is the same thing.
  pb := MakePixbufSized(96);
  if pb <> nil then begin
    g_object_set(G_OBJECT(dlg), 'image', gtk_image_new_from_pixbuf(pb), nil);
    g_object_unref(pb);
  end;
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
  Groups: array of record
    Id: Integer;
    List: PGSList;
  end;
  gi: Integer;
begin
  SetLength(Groups, 0);
  for i := 0 to High(Parent^.Sub) do begin
    node := Parent^.Sub[i];
    case node^.Kind of
      mkSep: gtk_menu_shell_append(GTK_MENU_SHELL(Dest), gtk_separator_menu_item_new);
      mkHeader: begin
        // Gray section header: visible, not clickable.
        item := gtk_menu_item_new_with_label(PChar(L(node^.Text)));
        gtk_widget_set_sensitive(item, False);
        gtk_menu_shell_append(GTK_MENU_SHELL(Dest), item);
      end;
      mkSubmenu: begin
        sub := gtk_menu_new;
        FillMenu(sub, node);
        item := gtk_menu_item_new_with_label(PChar(L(node^.Text)));
        gtk_menu_item_set_submenu(GTK_MENU_ITEM(item), sub);
        gtk_widget_show_all(sub);
        gtk_menu_shell_append(GTK_MENU_SHELL(Dest), item);
      end;
      mkRadio: begin
        group := nil;
        gi := Length(Groups) - 1;
        while gi >= 0 do begin
          if Groups[gi].Id = node^.RadioGroup then begin
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
        g_object_set_data(G_OBJECT(item), 'sa_action', gpointer(PtrUInt(Ord(node^.Action))));
        Bind(node, item, handler);
      end;
      mkCheck: begin
        item := gtk_check_menu_item_new_with_label(PChar(L(node^.Text)));
        gtk_menu_shell_append(GTK_MENU_SHELL(Dest), item);
        handler := g_signal_connect(item, 'toggled', TGCallback(@MenuSignalProc), nil);
        g_object_set_data(G_OBJECT(item), 'sa_action', gpointer(PtrUInt(Ord(node^.Action))));
        Bind(node, item, handler);
      end;
      mkItem: begin
        item := gtk_menu_item_new_with_label(PChar(L(node^.Text)));
        gtk_menu_shell_append(GTK_MENU_SHELL(Dest), item);
        handler := g_signal_connect(item, 'activate', TGCallback(@MenuSignalProc), nil);
        g_object_set_data(G_OBJECT(item), 'sa_action', gpointer(PtrUInt(Ord(node^.Action))));
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
  // action dispatcher. Blocking per item is NOT enough: activating a radio
  // item makes GTK deactivate the previously-active group member, emitting
  // 'toggled' on THAT item - outside the blocked window. Block every handler
  // for the whole pass instead.
  for i := 0 to High(Bindings) do
    with Bindings[i] do
      case Node^.Kind of
        mkCheck, mkRadio: g_signal_handler_block(Widget, Handler);
      end;
  try
    for i := 0 to High(Bindings) do
      with Bindings[i] do
        case Node^.Kind of
          mkCheck, mkRadio: gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(Widget), MenuActionState(Node^.Action));
        end;
  finally
    for i := 0 to High(Bindings) do
      with Bindings[i] do
        case Node^.Kind of
          mkCheck, mkRadio: g_signal_handler_unblock(Widget, Handler);
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

function HookAutostartState: Boolean; cdecl;
begin
  Result := IsAutoStartEnabled;
end;

procedure HookAutostartRequest(AEnable: Boolean); cdecl;
begin
  if AEnable then
    EnsureAutoStart
  else
    DisableAutoStart;
end;

// ---- Entry point ------------------------------------------------------------

// Platform config/hooks must be ready BEFORE the main body starts (the
// shared core reads config paths at any time); wired via initialization.
// A battery means a portable machine with a lid. Desktops (no battery, no
// lid) must not show lid UI or arm the guard, so everything lid-related is
// gated on this probe.
function HasBattery: Boolean;
var
  sr: TSearchRec;
  rc: Integer;
begin
  Result := False;
  rc := FindFirst('/sys/class/power_supply/BAT*', faAnyFile, sr);
  if rc = 0 then begin
    Result := True;
    FindClose(sr);
  end;
end;

var
  // Set by MigrateLidConfig when the first-run defaults were just written;
  // the bubble is shown from TrayCreate, after gtk_init.
  gNotifyLidPending: Boolean = False;

// One-time notification bubble announcing the awake-on-power default, so
// the behavior is never silent. libnotify is loaded dynamically: a desktop
// without the library or a notification daemon skips the bubble quietly.
procedure NotifyLidDefault;
type
  TNotifyInit = function(app_name: PAnsiChar): LongBool; cdecl;
  TNotifyNew = function(summary, body, icon: PAnsiChar; parent: Pointer): Pointer; cdecl;
  TNotifyShow = function(n: Pointer; err: Pointer): LongBool; cdecl;
const
  LIBNAMES: array[0..1] of PChar = ('libnotify.so.4', 'libnotify.so');
var
  h: TLibHandle;
  notify_init: TNotifyInit;
  notify_notification_new: TNotifyNew;
  notify_notification_show: TNotifyShow;
  n: Pointer;
  i: Integer;
begin
  h := NilHandle;
  for i := Low(LIBNAMES) to High(LIBNAMES) do begin
    h := LoadLibrary(LIBNAMES[i]);
    if h <> NilHandle then
      Break;
  end;
  if h = NilHandle then
    Exit;
  notify_init := TNotifyInit(GetProcAddress(h, 'notify_init'));
  notify_notification_new := TNotifyNew(GetProcAddress(h, 'notify_notification_new'));
  notify_notification_show := TNotifyShow(GetProcAddress(h, 'notify_notification_show'));
  if (notify_init = nil) or (notify_notification_new = nil) or (notify_notification_show = nil) then
    Exit;
  if not notify_init('StayAwake') then
    Exit;
  n := notify_notification_new(PAnsiChar(L('SNotifyLidTitle')), PAnsiChar(L('SNotifyLidBody')), nil, nil);
  if n <> nil then
    notify_notification_show(n, nil);
end;

// Legacy guard-style config maps onto the per-source files (the same
// mapping the macOS tray applies), and a fresh battery machine gets the
// shared default - awake on power - written explicitly, so the menu radios
// tell the truth from the first launch. The battery default (sleep on
// close) needs no file: a missing lid-battery-mins already means 0.
procedure MigrateLidConfig;
begin
  if (not TrayHooks.HasLid) or (TrayConfigDir = '') then
    Exit;
  if FileExists(LidFilePath) then begin
    // Old lid-mode file: express the same behavior per source, once.
    if (LidMode = 'block') and (not FileExists(LidAcAwakePath)) then begin
      SetLidAcAwake(True);
      if not FileExists(LidBatteryMinutesPath) then
        WriteConfigValue(LidBatteryMinutesPath, '15');
    end
    else if (LidMode = 'allow') and (not FileExists(LidAcAwakePath)) then
      SetLidAcAwake(False);
  end
  else if not FileExists(LidAcAwakePath) then begin
    SetLidAcAwake(True);
    gNotifyLidPending := True;
  end;
end;

procedure InitPlatformConfig;
begin
  TrayConfigDir := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if TrayConfigDir = '' then begin
    TrayConfigDir := GetEnvironmentVariable('HOME');
    if TrayConfigDir <> '' then
      TrayConfigDir := TrayConfigDir + '/.config';
  end;
  // Language packs ship beside the executable.
  TrayLangPackDir := ExtractFilePath(ExpandFileName(ParamStr(0)));

  TrayHooks.HasLid := HasBattery;
  TrayHooks.HasSleepNow := True; // systemctl suspend needs no privileges
  TrayHooks.LidPerSource := True; // same flat per-source lid menu as macOS
  TrayHooks.RefreshVisual := @HookRefreshVisual;
  TrayHooks.AutostartState := @HookAutostartState;
  TrayHooks.AutostartRequest := @HookAutostartRequest;
  TrayHooks.SleepNow := @HookSleepNow;
  TrayHooks.ApplyAwake := @HookApplyAwake;
  TrayHooks.ApplyLidMode := @HookApplyLidMode;
  TrayHooks.ApplyLanguage := @HookApplyLanguage;
  TrayHooks.ShowAbout := @HookShowAbout;
  TrayHooks.Quit := @HookQuit;
  TraySystemLang := @HookSystemLang;
  MigrateLidConfig;
end;

procedure TrayCreate;
var
  pb: PGdkPixbuf;
begin
  gtk_init(nil, nil);

  pb := MakePixbuf;
  if pb = nil then
    Exit;
  StatusIcon := gtk_status_icon_new_from_pixbuf(pb);
  g_object_unref(pb);
  gtk_status_icon_set_visible(StatusIcon, TRUE);
  gtk_status_icon_set_tooltip(StatusIcon, 'StayAwake');

  MenuRoot := BuildTrayMenu(TrayHooks.HasLid, TrayHooks.HasSleepNow, TrayHooks.LidPerSource);
  TrayMenu := gtk_menu_new;
  FillMenu(TrayMenu, MenuRoot);

  // Left click opens the same menu as right click: clicking the icon must
  // never change behavior silently.
  g_signal_connect(StatusIcon, 'activate', TGCallback(@TrayActivateSignal), nil);
  g_signal_connect(StatusIcon, 'popup-menu', TGCallback(@TrayPopupSignal), nil);

  TraySetVisual;
  // Self-heal: on every machine with a lid make sure the guard component is
  // installed and running - fresh installs rely on it for the default
  // awake-on-power policy; upgraded installs get their script refreshed.
  // Batteryless machines never touch the guard at all.
  if TrayHooks.HasLid then
    HookApplyLidMode;
  if gNotifyLidPending then begin
    gNotifyLidPending := False;
    NotifyLidDefault;
  end;
  gtk_main;
end;

initialization
  InitPlatformConfig;

finalization
  FreeTrayMenu(MenuRoot);

end.
