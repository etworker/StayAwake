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
  stayawake_autostart,
  stayawake_mover,
  Windows;

// Platform renderer for the shared tray core (stayawake_common): it binds the
// declarative menu tree to Shell_NotifyIcon + HMENU and implements the
// platform hooks. All strings, menu structure, state queries and click
// dispatching live in common and are identical on Linux/macOS.
// All user-visible text goes through UTF8Decode + the *W APIs so Chinese
// renders correctly regardless of the process code page.
// Menu command IDs are Ord(TMenuAction) (>= 1, maNone is never rendered).

function GetUserDefaultUILanguage: LANGID; stdcall; external 'kernel32' name 'GetUserDefaultUILanguage';

const
  WM_TRAYCALLBACK = WM_APP + 1;
  HWND_MESSAGE = HWND($FFFFFFFD);
  NIM_ADD = $00000000;
  NIM_MODIFY = $00000001;
  NIM_DELETE = $00000002;
  NIF_MESSAGE = $00000001;
  NIF_ICON = $00000002;
  NIF_TIP = $00000004;

type
  TItemBinding = record
    Node: PMenuNode;
    ParentMenu: HMENU;
  end;

var
  TrayHwnd: HWND = 0;
  TrayIcon: NativeUInt = 0;
  TrayMenu: HMENU = 0;
  MenuRoot: PMenuNode = nil;
  Bindings: array of TItemBinding;

function CreateIconFromPixels(const Pixels: TIconPixels): NativeUInt; forward;

procedure TipToBuf(const S: WideString; Dst: PWideChar; MaxLen: Integer);
var
  n: Integer;
begin
  n := Length(S);
  if n > MaxLen then
    n := MaxLen;
  if n > 0 then
    Move(S[1], Dst^, n * SizeOf(WideChar));
  (Dst + n)^ := #0;
end;

function HookSystemLang: string; cdecl;
begin
  // GetUserDefaultUILanguage: primary language id 0x04 = Chinese.
  if (GetUserDefaultUILanguage and $FF) = $04 then
    Result := 'zh-Hans'
  else
    Result := 'en-US';
end;

// ---- Platform hooks ---------------------------------------------------------

procedure HookRefreshVisual; cdecl;
var
  hIcon: NativeUInt;
  pixels: TIconPixels;
  nid: NOTIFYICONDATAW;
  tip: WideString;
  i: Integer;
begin
  if TrayHwnd = 0 then
    Exit;
  GenerateTrayIconPixels(AppActive, pixels);
  hIcon := CreateIconFromPixels(pixels);
  if hIcon = 0 then
    Exit;
  if TrayIcon <> 0 then
    DestroyIcon(TrayIcon);
  TrayIcon := hIcon;
  tip := UTF8Decode(TrayTooltip);
  FillChar(nid, SizeOf(nid), 0);
  nid.cbSize := SizeOf(nid);
  nid.Wnd := TrayHwnd;
  nid.uID := 1;
  nid.uFlags := NIF_ICON or NIF_TIP;
  nid.hIcon := hIcon;
  TipToBuf(tip, @nid.szTip[0], High(nid.szTip));
  Shell_NotifyIconW(NIM_MODIFY, @nid);
  for i := 0 to High(Bindings) do
    with Bindings[i] do
      case Node^.Kind of
        mkCheck, mkRadio:
        begin
          if MenuActionState(Node^.Action) then
            CheckMenuItem(ParentMenu, Ord(Node^.Action), MF_BYCOMMAND or MF_CHECKED)
          else
            CheckMenuItem(ParentMenu, Ord(Node^.Action), MF_BYCOMMAND or MF_UNCHECKED);
        end;
      end;
end;

procedure HookApplyAwake; cdecl;
begin
  UpdateExecutionState;
  // Pausing must wake the mover so it clears its own per-thread ES_* flags.
  if not AppActive then
    WakeMoverThread;
end;

procedure HookApplyLanguage; cdecl;
var
  i: Integer;
  wide: WideString;
begin
  for i := 0 to High(Bindings) do
  begin
    wide := UTF8Decode(L(Bindings[i].Node^.Text));
    ModifyMenuW(Bindings[i].ParentMenu, Ord(Bindings[i].Node^.Action),
      MF_BYCOMMAND or MF_STRING, Ord(Bindings[i].Node^.Action), PWideChar(wide));
  end;
  HookRefreshVisual;
end;

procedure HookShowAbout; cdecl;
var
  Msg, Title: WideString;
begin
  Msg := UTF8Decode(AboutText);
  Title := UTF8Decode(L(SAbout));
  MessageBoxW(0, PWideChar(Msg), PWideChar(Title), MB_OK or MB_ICONINFORMATION);
end;

procedure HookQuit; cdecl;
var
  nid: NOTIFYICONDATAW;
begin
  if TrayHwnd <> 0 then begin
    FillChar(nid, SizeOf(nid), 0);
    nid.cbSize := SizeOf(nid);
    nid.Wnd := TrayHwnd;
    nid.uID := 1;
    Shell_NotifyIconW(NIM_DELETE, @nid);
    PostMessage(TrayHwnd, WM_DESTROY, 0, 0);
  end;
end;

// ---- Icon artwork -----------------------------------------------------------

function CreateIconFromPixels(const Pixels: TIconPixels): NativeUInt;
var
  dc: HDC;
  bmi: BITMAPINFO;
  bits: Pointer;
  hbmColor, hbmMask: HBITMAP;
  info: TIconInfo;
  src, dst: PByte;
  i: Integer;
begin
  Result := 0;
  dc := GetDC(0);
  try
    FillChar(bmi, SizeOf(bmi), 0);
    bmi.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth := ICON_SIZE;
    bmi.bmiHeader.biHeight := -ICON_SIZE;
    bmi.bmiHeader.biPlanes := 1;
    bmi.bmiHeader.biBitCount := 32;
    bmi.bmiHeader.biCompression := BI_RGB;
    hbmColor := CreateDIBSection(dc, bmi, DIB_RGB_COLORS, bits, 0, 0);
    if hbmColor = 0 then
      Exit;
    try
      src := @Pixels;
      dst := PByte(bits);
      for i := 0 to ICON_SIZE * ICON_SIZE - 1 do begin
        dst[0] := src[2];
        dst[1] := src[1];
        dst[2] := src[0];
        dst[3] := src[3];
        Inc(src, 4);
        Inc(dst, 4);
      end;
      hbmMask := CreateBitmap(ICON_SIZE, ICON_SIZE, 1, 1, nil);
      if hbmMask = 0 then
        Exit;
      try
        FillChar(info, SizeOf(info), 0);
        info.fIcon := True;
        info.hbmMask := hbmMask;
        info.hbmColor := hbmColor;
        Result := NativeUInt(CreateIconIndirect(info));
      finally
        DeleteObject(hbmMask);
      end;
    finally
      DeleteObject(hbmColor);
    end;
  finally
    ReleaseDC(0, dc);
  end;
end;

// ---- Menu construction ------------------------------------------------------

procedure FillMenu(Dest: HMENU; Parent: PMenuNode);
var
  i: Integer;
  node: PMenuNode;
  sub: HMENU;
begin
  for i := 0 to High(Parent^.Sub) do
  begin
    node := Parent^.Sub[i];
    case node^.Kind of
      mkSep:
        AppendMenuW(Dest, MF_SEPARATOR, 0, nil);
      mkSubmenu:
      begin
        sub := CreatePopupMenu;
        FillMenu(sub, node);
        AppendMenuW(Dest, MF_POPUP, HMENU(sub),
          PWideChar(UTF8Decode(L(node^.Text))));
      end;
    else
      AppendMenuW(Dest, MF_STRING, Ord(node^.Action),
        PWideChar(UTF8Decode(L(node^.Text))));
      // Remember the owning menu so Check/ModifyMenuItem can reach items
      // inside submenus.
      SetLength(Bindings, Length(Bindings) + 1);
      Bindings[High(Bindings)].Node := node;
      Bindings[High(Bindings)].ParentMenu := Dest;
    end;
  end;
end;

procedure ShowTrayMenu;
var
  pt: TPoint;
begin
  SetForegroundWindow(TrayHwnd);
  GetCursorPos(pt);
  TrackPopupMenu(TrayMenu, TPM_LEFTALIGN or TPM_BOTTOMALIGN or TPM_RIGHTBUTTON, pt.x, pt.y, 0, TrayHwnd, nil);
  PostMessage(TrayHwnd, WM_NULL, 0, 0);
end;

function TrayWndProc(hwnd: HWND; msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
begin
  Result := 0;
  case msg of
    WM_TRAYCALLBACK:
      // Left click opens the same menu as right click: clicking the icon must
      // never change behavior silently.
      case lParam of
        WM_LBUTTONUP, WM_RBUTTONUP, WM_CONTEXTMENU: ShowTrayMenu;
      end;
    WM_COMMAND:
      MenuActionInvoke(TMenuAction(wParam and $FFFF));
    WM_DESTROY: PostQuitMessage(0);
  else
    Result := DefWindowProc(hwnd, msg, wParam, lParam);
  end;
end;

// ---- Entry point ------------------------------------------------------------

// Platform config/hooks must be ready BEFORE the main body starts (the
// shared core reads config paths at any time); wired via initialization.
procedure InitPlatformConfig;
var
  Buf: array[0..1023] of Char;
begin
  // %APPDATA% is always set for interactive sessions; '.' keeps config
  // reads harmless (file simply not found) in odd service contexts.
  if GetEnvironmentVariable('APPDATA', Buf, SizeOf(Buf)) > 0 then
    TrayConfigDir := Buf
  else
    TrayConfigDir := '.';

  TrayHooks.HasLid := False;
  TrayHooks.RefreshVisual := @HookRefreshVisual;
  TrayHooks.ApplyAwake := @HookApplyAwake;
  TrayHooks.ApplyLidMode := nil;
  TrayHooks.ApplyLanguage := @HookApplyLanguage;
  TrayHooks.ShowAbout := @HookShowAbout;
  TrayHooks.Quit := @HookQuit;
  TraySystemLang := @HookSystemLang;
end;

procedure TrayCreate;
var
  wc: TWndClass;
  nid: NOTIFYICONDATAW;
  pixels: TIconPixels;
  msg: TMsg;
  tip: WideString;
begin
  FillChar(wc, SizeOf(wc), 0);
  wc.lpfnWndProc := @TrayWndProc;
  wc.hInstance := GetModuleHandle(nil);
  wc.lpszClassName := 'StayAwakeTrayWindow';
  RegisterClass(wc);

  TrayHwnd :=
      CreateWindowEx(
          0,
          'StayAwakeTrayWindow',
          'StayAwake',
          0,
          CW_USEDEFAULT,
          CW_USEDEFAULT,
          0,
          0,
          HWND_MESSAGE,
          0,
          GetModuleHandle(nil),
          nil
      );
  ShowWindow(TrayHwnd, SW_HIDE);

  MenuRoot := BuildTrayMenu(TrayHooks.HasLid);
  TrayMenu := CreatePopupMenu;
  FillMenu(TrayMenu, MenuRoot);

  GenerateTrayIconPixels(AppActive, pixels);
  TrayIcon := CreateIconFromPixels(pixels);

  tip := UTF8Decode(TrayTooltip);
  FillChar(nid, SizeOf(nid), 0);
  nid.cbSize := SizeOf(nid);
  nid.Wnd := TrayHwnd;
  nid.uID := 1;
  nid.uFlags := NIF_ICON or NIF_MESSAGE or NIF_TIP;
  nid.uCallbackMessage := WM_TRAYCALLBACK;
  nid.hIcon := TrayIcon;
  TipToBuf(tip, @nid.szTip[0], High(nid.szTip));
  Shell_NotifyIconW(NIM_ADD, @nid);

  HookRefreshVisual;

  while GetMessage(msg, 0, 0, 0) do begin
    TranslateMessage(msg);
    DispatchMessage(msg);
  end;
end;

initialization
  InitPlatformConfig;

end.
