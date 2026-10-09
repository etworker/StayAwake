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

// Menu structure and behavior mirror the Linux tray (src/linux/stayawake_tray.pas):
// single checkable "Keep Awake" row, localized labels (EN/中文) with an in-menu
// language switcher, and left click opening the same menu as right click. Keep
// the SAwake/SLidTitle/... string tables 1:1 across both units. The Linux-only
// lid-close submenu has no Windows counterpart (logind guard) and is absent.
// All user-visible text goes through UTF8Decode + the *W APIs so Chinese
// renders correctly regardless of the process code page.

function GetUserDefaultUILanguage: LANGID; stdcall; external 'kernel32' name 'GetUserDefaultUILanguage';

const
  WM_TRAYCALLBACK = WM_APP + 1;
  HWND_MESSAGE = HWND($FFFFFFFD);
  ID_AWAKE = 1001;
  ID_AUTOSTART = 1002;
  ID_LANG_TITLE = 1003;
  ID_LANG_AUTO = 1004;
  ID_LANG_EN = 1005;
  ID_LANG_ZH = 1006;
  ID_ABOUT = 1007;
  ID_QUIT = 1008;
  NIM_ADD = $00000000;
  NIM_MODIFY = $00000001;
  NIM_DELETE = $00000002;
  NIF_MESSAGE = $00000001;
  NIF_ICON = $00000002;
  NIF_TIP = $00000004;

type
  TTrayLang = (tlEn, tlZh);
  TStrMap = array[TTrayLang] of string;

const
  // All user-visible strings, per language. Menu labels state the action
  // and its consequence so each item is unambiguous. Keep 1:1 with Linux.
  SAwake: TStrMap = ('Keep Awake (block idle sleep)', '保持清醒(阻止闲置睡眠)');
  SAutoStart: TStrMap = ('Run at Login', '开机自启');
  SLangTitle: TStrMap = ('Language', '语言 / Language');
  SLangAuto: TStrMap = ('Follow System', '跟随系统');
  SAbout: TStrMap = ('About StayAwake', '关于 StayAwake');
  SQuit: TStrMap = ('Quit', '退出');
  STipWork: TStrMap = ('StayAwake - preventing sleep', 'StayAwake - 防睡中');
  STipPause: TStrMap = ('StayAwake - paused', 'StayAwake - 已暂停');

var
  TrayHwnd: HWND = 0;
  TrayIcon: NativeUInt = 0;
  TrayMenu: HMENU = 0;
  LangMenu: HMENU = 0;

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

// ---- Config (language choice), mirrors the Linux tray ----------------------

function ConfigDir: string;
var
  Buf: array[0..1023] of Char;
begin
  // %APPDATA% is always set for interactive sessions; '.' keeps config
  // reads harmless (file simply not found) in odd service contexts.
  Result := '.';
  if GetEnvironmentVariable('APPDATA', Buf, SizeOf(Buf)) > 0 then
    Result := Buf;
end;

function LangFilePath: string;
begin
  Result := ConfigDir + '\stayawake\lang';
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
  Stored: string;
begin
  Result := tlEn;
  Stored := LowerCase(ReadConfigValue(LangFilePath, ''));
  if Stored = 'zh' then
    Exit(tlZh);
  if Stored = 'en' then
    Exit(tlEn);
  // No explicit choice yet: follow the user's UI language (zh-* -> Chinese).
  if (GetUserDefaultUILanguage and $FF) = $04 then
    Result := tlZh;
end;

function L(M: TStrMap): string;
begin
  Result := M[CurrentLang];
end;

// ---- Tray visuals -----------------------------------------------------------

procedure TraySetVisual; forward;

// NOTIFYICONDATAW keeps the localized tooltip readable on every code page.
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

procedure TrayTipText(var Tip: WideString);
begin
  if AppActive then
    Tip := UTF8Decode(L(STipWork))
  else
    Tip := UTF8Decode(L(STipPause));
end;

procedure ShowAbout;
var
  Msg, Title: WideString;
begin
  Msg :=
      UTF8Decode(
          APP_NAME
              + ' '
              + APP_VERSION
              + #10#10
              + 'Prevents idle sleep by moving the mouse every '
              + IntToStr(INTERVAL_SECS)
              + ' seconds.'
              + #10#10
              + '防止系统因「闲置」而睡眠 / 熄屏 / 锁屏。'
      );
  Title := UTF8Decode(L(SAbout));
  MessageBoxW(0, PWideChar(Msg), PWideChar(Title), MB_OK or MB_ICONINFORMATION);
end;

procedure RefreshMenu; forward;

// Left click opens the same menu as right click: clicking the icon must
// never change behavior silently.
procedure ShowTrayMenu;
var
  pt: TPoint;
begin
  RefreshMenu;
  SetForegroundWindow(TrayHwnd);
  GetCursorPos(pt);
  TrackPopupMenu(TrayMenu, TPM_LEFTALIGN or TPM_BOTTOMALIGN or TPM_RIGHTBUTTON, pt.x, pt.y, 0, TrayHwnd, nil);
  PostMessage(TrayHwnd, WM_NULL, 0, 0);
end;

procedure TraySetVisual;
var
  hIcon: NativeUInt;
  pixels: TIconPixels;
  nid: NOTIFYICONDATAW;
  tip: WideString;
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
  TrayTipText(tip);
  FillChar(nid, SizeOf(nid), 0);
  nid.cbSize := SizeOf(nid);
  nid.Wnd := TrayHwnd;
  nid.uID := 1;
  nid.uFlags := NIF_ICON or NIF_TIP;
  nid.hIcon := hIcon;
  TipToBuf(tip, @nid.szTip[0], High(nid.szTip));
  Shell_NotifyIconW(NIM_MODIFY, @nid);
end;

// ---- Language ---------------------------------------------------------------

procedure SetAllLabels;
begin
  if TrayMenu = 0 then
    Exit;
  ModifyMenuW(TrayMenu, ID_AWAKE, MF_BYCOMMAND or MF_STRING, ID_AWAKE, PWideChar(UTF8Decode(L(SAwake))));
  ModifyMenuW(TrayMenu, ID_AUTOSTART, MF_BYCOMMAND or MF_STRING, ID_AUTOSTART, PWideChar(UTF8Decode(L(SAutoStart))));
  ModifyMenuW(LangMenu, ID_LANG_AUTO, MF_BYCOMMAND or MF_STRING, ID_LANG_AUTO, PWideChar(UTF8Decode(L(SLangAuto))));
  ModifyMenuW(
      TrayMenu,
      ID_LANG_TITLE,
      MF_BYCOMMAND or MF_POPUP,
      UINT_PTR(LangMenu),
      PWideChar(UTF8Decode(L(SLangTitle)))
  );
  ModifyMenuW(TrayMenu, ID_ABOUT, MF_BYCOMMAND or MF_STRING, ID_ABOUT, PWideChar(UTF8Decode(L(SAbout))));
  ModifyMenuW(TrayMenu, ID_QUIT, MF_BYCOMMAND or MF_STRING, ID_QUIT, PWideChar(UTF8Decode(L(SQuit))));
  TraySetVisual;
end;

procedure ApplyLanguage(ALang: string);
begin
  WriteConfigValue(LangFilePath, ALang);
  SetAllLabels;
end;

// ---- Menu actions -----------------------------------------------------------

procedure RefreshMenu;
var
  Lang: string;
begin
  if TrayMenu = 0 then
    Exit;
  if AppActive then
    CheckMenuItem(TrayMenu, ID_AWAKE, MF_BYCOMMAND or MF_CHECKED)
  else
    CheckMenuItem(TrayMenu, ID_AWAKE, MF_BYCOMMAND or MF_UNCHECKED);
  if IsAutoStartEnabled then
    CheckMenuItem(TrayMenu, ID_AUTOSTART, MF_BYCOMMAND or MF_CHECKED)
  else
    CheckMenuItem(TrayMenu, ID_AUTOSTART, MF_BYCOMMAND or MF_UNCHECKED);
  Lang := LowerCase(ReadConfigValue(LangFilePath, ''));
  if (Lang <> 'en') and (Lang <> 'zh') then
    CheckMenuItem(TrayMenu, ID_LANG_AUTO, MF_BYCOMMAND or MF_CHECKED)
  else
    CheckMenuItem(TrayMenu, ID_LANG_AUTO, MF_BYCOMMAND or MF_UNCHECKED);
  if Lang = 'en' then
    CheckMenuItem(TrayMenu, ID_LANG_EN, MF_BYCOMMAND or MF_CHECKED)
  else
    CheckMenuItem(TrayMenu, ID_LANG_EN, MF_BYCOMMAND or MF_UNCHECKED);
  if Lang = 'zh' then
    CheckMenuItem(TrayMenu, ID_LANG_ZH, MF_BYCOMMAND or MF_CHECKED)
  else
    CheckMenuItem(TrayMenu, ID_LANG_ZH, MF_BYCOMMAND or MF_UNCHECKED);
end;

procedure TrayQuit; forward;

function TrayWndProc(hwnd: HWND; msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
begin
  Result := 0;
  case msg of
    WM_TRAYCALLBACK:
      case lParam of
        WM_LBUTTONUP, WM_RBUTTONUP, WM_CONTEXTMENU: ShowTrayMenu;
      end;
    WM_COMMAND:
      case wParam of
        ID_AWAKE: begin
          // Checked = prevent idle sleep; unchecked = normal system policy.
          AppActive := not AppActive;
          UpdateExecutionState;
          // Pausing must wake the mover so it clears its own per-thread ES_* flags.
          if not AppActive then
            WakeMoverThread;
          TraySetVisual;
        end;
        ID_AUTOSTART: begin
          if IsAutoStartEnabled then
            DisableAutoStart
          else
            EnsureAutoStart;
          // Sync the checkbox immediately instead of waiting for the next popup.
          RefreshMenu;
        end;
        ID_LANG_AUTO: ApplyLanguage('');
        ID_LANG_EN: ApplyLanguage('en');
        ID_LANG_ZH: ApplyLanguage('zh');
        ID_ABOUT: ShowAbout;
        ID_QUIT: TrayQuit;
      end;
    WM_DESTROY: PostQuitMessage(0);
  else
    Result := DefWindowProc(hwnd, msg, wParam, lParam);
  end;
end;

procedure TrayQuit;
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

  LangMenu := CreatePopupMenu;
  TrayMenu := CreatePopupMenu;
  AppendMenuW(TrayMenu, MF_STRING, ID_AWAKE, PWideChar(UTF8Decode(L(SAwake))));
  AppendMenuW(TrayMenu, MF_SEPARATOR, 0, nil);
  AppendMenuW(TrayMenu, MF_STRING, ID_AUTOSTART, PWideChar(UTF8Decode(L(SAutoStart))));
  AppendMenuW(TrayMenu, MF_SEPARATOR, 0, nil);
  AppendMenuW(LangMenu, MF_STRING, ID_LANG_AUTO, PWideChar(UTF8Decode(L(SLangAuto))));
  AppendMenuW(LangMenu, MF_STRING, ID_LANG_EN, PWideChar(UTF8Decode('English')));
  AppendMenuW(LangMenu, MF_STRING, ID_LANG_ZH, PWideChar(UTF8Decode('中文')));
  AppendMenuW(TrayMenu, MF_POPUP, HMENU(LangMenu), PWideChar(UTF8Decode(L(SLangTitle))));
  AppendMenuW(TrayMenu, MF_SEPARATOR, 0, nil);
  AppendMenuW(TrayMenu, MF_STRING, ID_ABOUT, PWideChar(UTF8Decode(L(SAbout))));
  AppendMenuW(TrayMenu, MF_SEPARATOR, 0, nil);
  AppendMenuW(TrayMenu, MF_STRING, ID_QUIT, PWideChar(UTF8Decode(L(SQuit))));

  GenerateTrayIconPixels(AppActive, pixels);
  TrayIcon := CreateIconFromPixels(pixels);

  TrayTipText(tip);
  FillChar(nid, SizeOf(nid), 0);
  nid.cbSize := SizeOf(nid);
  nid.Wnd := TrayHwnd;
  nid.uID := 1;
  nid.uFlags := NIF_ICON or NIF_MESSAGE or NIF_TIP;
  nid.uCallbackMessage := WM_TRAYCALLBACK;
  nid.hIcon := TrayIcon;
  TipToBuf(tip, @nid.szTip[0], High(nid.szTip));
  Shell_NotifyIconW(NIM_ADD, @nid);

  TraySetVisual;
  RefreshMenu;

  while GetMessage(msg, 0, 0, 0) do begin
    TranslateMessage(msg);
    DispatchMessage(msg);
  end;
end;

end.
