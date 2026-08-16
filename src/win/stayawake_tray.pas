unit stayawake_tray;

{$mode objfpc}{$H+}

interface

procedure TrayCreate;

implementation

uses
  SysUtils,
  stayawake_common,
  stayawake_autostart,
  Windows;

const
  WM_TRAYCALLBACK = WM_APP + 1;
  HWND_MESSAGE = HWND($FFFFFFFD);
  ID_START = 1001;
  ID_STOP = 1002;
  ID_AUTOSTART = 1003;
  ID_ABOUT = 1004;
  ID_QUIT = 1005;
  NIM_ADD = $00000000;
  NIM_MODIFY = $00000001;
  NIM_DELETE = $00000002;
  NIF_MESSAGE = $00000001;
  NIF_ICON = $00000002;
  NIF_TIP = $00000004;

var
  TrayHwnd: HWND = 0;
  TrayIcon: NativeUInt = 0;
  TrayMenu: HMENU = 0;

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
      for i := 0 to ICON_SIZE * ICON_SIZE - 1 do
      begin
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

procedure TraySetVisual; forward;
procedure TrayToggle; forward;
procedure TrayQuit; forward;

function TrayTipText: string;
begin
  if AppActive then
    Result := 'StayAwake - Working'
  else
    Result := 'StayAwake - Paused';
end;

procedure ShowAbout;
var
  Msg: string;
begin
  Msg := APP_NAME + ' ' + APP_VERSION + #13#10 + #13#10 +
         'Prevents the system from sleeping by moving' + #13#10 +
         'the mouse every ' + IntToStr(INTERVAL_SECS) + ' seconds.';
  MessageBoxA(0, PChar(Msg), 'About StayAwake', MB_OK or MB_ICONINFORMATION);
end;

procedure RefreshMenu;
begin
  if TrayMenu = 0 then
    Exit;
  if AppActive then
  begin
    EnableMenuItem(TrayMenu, ID_START, MF_BYCOMMAND or MF_GRAYED);
    EnableMenuItem(TrayMenu, ID_STOP, MF_BYCOMMAND or MF_ENABLED);
  end
  else
  begin
    EnableMenuItem(TrayMenu, ID_START, MF_BYCOMMAND or MF_ENABLED);
    EnableMenuItem(TrayMenu, ID_STOP, MF_BYCOMMAND or MF_GRAYED);
  end;
  if IsAutoStartEnabled then
    CheckMenuItem(TrayMenu, ID_AUTOSTART, MF_BYCOMMAND or MF_CHECKED)
  else
    CheckMenuItem(TrayMenu, ID_AUTOSTART, MF_BYCOMMAND or MF_UNCHECKED);
end;

function TrayWndProc(hwnd: HWND; msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  pt: TPoint;
begin
  Result := 0;
  case msg of
    WM_TRAYCALLBACK:
      case lParam of
        WM_LBUTTONUP:
          TrayToggle;
        WM_RBUTTONUP, WM_CONTEXTMENU:
          begin
            RefreshMenu;
            SetForegroundWindow(TrayHwnd);
            GetCursorPos(pt);
            TrackPopupMenu(TrayMenu, TPM_LEFTALIGN or TPM_BOTTOMALIGN or TPM_RIGHTBUTTON,
              pt.x, pt.y, 0, TrayHwnd, nil);
            PostMessage(TrayHwnd, WM_NULL, 0, 0);
          end;
      end;
    WM_COMMAND:
      case wParam of
        ID_START:
          begin
            if not AppActive then
            begin
              AppActive := True;
              TraySetVisual;
            end;
          end;
        ID_STOP:
          begin
            if AppActive then
            begin
              AppActive := False;
              TraySetVisual;
            end;
          end;
        ID_AUTOSTART:
          begin
            if IsAutoStartEnabled then
              DisableAutoStart
            else
              EnsureAutoStart;
          end;
        ID_ABOUT:
          ShowAbout;
        ID_QUIT:
          TrayQuit;
      end;
    WM_DESTROY:
      PostQuitMessage(0);
  else
    Result := DefWindowProc(hwnd, msg, wParam, lParam);
  end;
end;

procedure TraySetVisual;
var
  hIcon: NativeUInt;
  pixels: TIconPixels;
  nid: NOTIFYICONDATA;
  tip: string;
begin
  if TrayHwnd = 0 then
    Exit;
  GenerateIconPixels(AppActive, pixels);
  hIcon := CreateIconFromPixels(pixels);
  if hIcon = 0 then
    Exit;
  if TrayIcon <> 0 then
    DestroyIcon(TrayIcon);
  TrayIcon := hIcon;
  tip := TrayTipText;
  FillChar(nid, SizeOf(nid), 0);
  nid.cbSize := SizeOf(nid);
  nid.Wnd := TrayHwnd;
  nid.uID := 1;
  nid.uFlags := NIF_ICON or NIF_TIP;
  nid.hIcon := hIcon;
  StrPLCopy(@nid.szTip[0], tip, Length(nid.szTip) - 1);
  Shell_NotifyIcon(NIM_MODIFY, @nid);
end;

procedure TrayToggle;
begin
  AppActive := not AppActive;
  TraySetVisual;
end;

procedure TrayQuit;
var
  nid: NOTIFYICONDATA;
begin
  if TrayHwnd <> 0 then
  begin
    FillChar(nid, SizeOf(nid), 0);
    nid.cbSize := SizeOf(nid);
    nid.Wnd := TrayHwnd;
    nid.uID := 1;
    Shell_NotifyIcon(NIM_DELETE, @nid);
    PostMessage(TrayHwnd, WM_DESTROY, 0, 0);
  end;
end;

procedure TrayCreate;
var
  wc: TWndClass;
  nid: NOTIFYICONDATA;
  pixels: TIconPixels;
  msg: TMsg;
begin
  FillChar(wc, SizeOf(wc), 0);
  wc.lpfnWndProc := @TrayWndProc;
  wc.hInstance := GetModuleHandle(nil);
  wc.lpszClassName := 'StayAwakeTrayWindow';
  RegisterClass(wc);

  TrayHwnd := CreateWindowEx(0, 'StayAwakeTrayWindow', 'StayAwake', 0,
    CW_USEDEFAULT, CW_USEDEFAULT, 0, 0, HWND_MESSAGE, 0, GetModuleHandle(nil), nil);
  ShowWindow(TrayHwnd, SW_HIDE);

  TrayMenu := CreatePopupMenu;
  AppendMenu(TrayMenu, MF_STRING, ID_START, 'Start Awake');
  AppendMenu(TrayMenu, MF_STRING, ID_STOP, 'Stop Awake');
  AppendMenu(TrayMenu, MF_SEPARATOR, 0, nil);
  AppendMenu(TrayMenu, MF_STRING, ID_AUTOSTART, 'Start on Login');
  AppendMenu(TrayMenu, MF_SEPARATOR, 0, nil);
  AppendMenu(TrayMenu, MF_STRING, ID_ABOUT, 'About...');
  AppendMenu(TrayMenu, MF_SEPARATOR, 0, nil);
  AppendMenu(TrayMenu, MF_STRING, ID_QUIT, 'Quit');

  GenerateIconPixels(AppActive, pixels);
  TrayIcon := CreateIconFromPixels(pixels);

  FillChar(nid, SizeOf(nid), 0);
  nid.cbSize := SizeOf(nid);
  nid.Wnd := TrayHwnd;
  nid.uID := 1;
  nid.uFlags := NIF_ICON or NIF_MESSAGE or NIF_TIP;
  nid.uCallbackMessage := WM_TRAYCALLBACK;
  nid.hIcon := TrayIcon;
  StrPLCopy(@nid.szTip[0], 'StayAwake', Length(nid.szTip));
  Shell_NotifyIcon(NIM_ADD, @nid);

  TraySetVisual;
  RefreshMenu;

  while GetMessage(msg, 0, 0, 0) do
  begin
    TranslateMessage(msg);
    DispatchMessage(msg);
  end;
end;

end.