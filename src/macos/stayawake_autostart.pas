unit stayawake_autostart;

{$mode objfpc}{$H+}
{$modeswitch objectivec1}

interface

procedure EnsureAutoStart;
function IsAutoStartEnabled: Boolean;
procedure DisableAutoStart;

implementation

uses
  SysUtils,
  Classes,
  dynlibs,
  ctypes,
  stayawake_common;

// Login-item registration via SMAppService (macOS 13+). This is the modern
// API behind "System Settings > General > Login Items", works user-level and
// does NOT need write access to ~/Library/LaunchAgents — which is root-owned
// on managed machines, silently denying the previous plist-file approach.
// When the framework/class is unavailable (macOS < 13) we fall back to the
// legacy LaunchAgents plist file.

type
  TMsgSendId = function(obj: id; sel: SEL): id; cdecl;
  TMsgSendInt = function(obj: id; sel: SEL): NSInteger; cdecl;
  TMsgSendErr = function(obj: id; sel: SEL; err: Pointer): id; cdecl;

function objc_getClass(name: PAnsiChar): id; cdecl; external 'objc' name 'objc_getClass';
function sel_getUid(name: PAnsiChar): SEL; cdecl; external 'objc' name 'sel_getUid';
function objc_msgSend(obj: id; sel: SEL): id; cdecl; external 'objc' name 'objc_msgSend';
function objc_msgSend_int(obj: id; sel: SEL): NSInteger; cdecl; external 'objc' name 'objc_msgSend';
function objc_msgSend_err(obj: id; sel: SEL; err: Pointer): id; cdecl; external 'objc' name 'objc_msgSend';
function objc_msgSend_p(obj: id; sel: SEL; p: Pointer): id; cdecl; external 'objc' name 'objc_msgSend';

var
  SMHandle: TLibHandle = NilHandle;
  SMClassChecked: Boolean = False;
  SMService: id = nil;

// SMAppServiceStatus: 0=notRegistered 1=enabled 2=requiresApproval 3=notFound
function SMEnabledStatus(st: NSInteger): Boolean; inline;
begin
  Result := (st = 1) or (st = 2);
end;

function SMAppServiceAvailable: Boolean;
begin
  if not SMClassChecked then
  begin
    SMClassChecked := True;
    SMHandle := LoadLibrary(
      '/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement');
    if SMHandle <> NilHandle then
    begin
      if objc_getClass('SMAppService') <> nil then
        SMService := objc_msgSend(objc_getClass('SMAppService'),
          sel_getUid('mainAppService'));
    end;
  end;
  Result := SMService <> nil;
end;

// ---- Legacy LaunchAgents plist fallback (macOS < 13) ------------------------

function AutoStartPath: string;
var
  Home: string;
begin
  Home := GetEnvironmentVariable('HOME');
  if Home = '' then
    Exit('');
  Result := Home + '/Library/LaunchAgents/com.stayawake.plist';
end;

function AutoStartPathMatches: Boolean;
var
  Path: string;
  sl: TStringList;
  i: Integer;
  s, ExePath: string;
begin
  Result := False;
  Path := AutoStartPath;
  if not FileExists(Path) then
    Exit;
  ExePath := ExpandFileName(ParamStr(0));
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(Path);
      for i := 0 to sl.Count - 1 do
      begin
        s := Trim(sl[i]);
        if (Pos('<string>', s) > 0) and (Pos('</string>', s) > 0) then
        begin
          s := Copy(s, Pos('<string>', s) + 8, MaxInt);
          s := Copy(s, 1, Pos('</string>', s) - 1);
          if SameText(s, ExePath) then
          begin
            Result := True;
            Exit;
          end;
        end;
      end;
    except
      on E: Exception do
        ;
    end;
  finally
    sl.Free;
  end;
end;

function LegacyWriteAutoStartFile: Boolean;
var
  Path: string;
  sl: TStringList;
begin
  Result := False;
  Path := AutoStartPath;
  if Path = '' then
    Exit;
  if not ForceDirectories(ExtractFilePath(Path)) then
    Exit;
  sl := TStringList.Create;
  try
    sl.Add('<?xml version="1.0" encoding="UTF-8"?>');
    sl.Add('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">');
    sl.Add('<plist version="1.0">');
    sl.Add('<dict>');
    sl.Add('  <key>Label</key>');
    sl.Add('  <string>com.stayawake</string>');
    sl.Add('  <key>ProgramArguments</key>');
    sl.Add('  <array>');
    sl.Add('    <string>' + ExpandFileName(ParamStr(0)) + '</string>');
    sl.Add('  </array>');
    sl.Add('  <key>RunAtLoad</key>');
    sl.Add('  <true/>');
    sl.Add('</dict>');
    sl.Add('</plist>');
    try
      sl.SaveToFile(Path);
      Result := True;
    except
      // The login-item cannot be registered in this environment (e.g. the
      // LaunchAgents directory is not writable). Writing must not crash the
      // app; the caller decides whether to surface the failure.
      on E: Exception do
        ;
    end;
  finally
    sl.Free;
  end;
end;

// Last-resort reminder when neither SMAppService nor the plist fallback
// could register the login item: point at the manual route. No commands to
// copy - manual login items are just a System Settings toggle.
procedure ShowAutoStartFailHint;
const
  ATitle: TStrMap = ('开机自启设置失败', 'Auto-start setup failed');
  AInfo: TStrMap = ('无法写入登录项。请在 系统设置 → 通用 → 登录项 中手动添加 StayAwake。',
    'Could not register the login item. Add StayAwake manually in System Settings > General > Login Items.');

  function NSStr(const s: string): id;
  begin
    Result := objc_msgSend_p(objc_getClass('NSString'),
      sel_getUid('stringWithUTF8String:'), PChar(s));
  end;

var
  alert: id;
begin
  alert := objc_msgSend(objc_msgSend(objc_getClass('NSAlert'),
    sel_getUid('alloc')), sel_getUid('init'));
  objc_msgSend_p(alert, sel_getUid('setMessageText:'), NSStr(L(ATitle)));
  objc_msgSend_p(alert, sel_getUid('setInformativeText:'), NSStr(L(AInfo)));
  objc_msgSend(alert, sel_getUid('runModal'));
  objc_msgSend(alert, sel_getUid('release'));
end;

// ---- Public API -------------------------------------------------------------

procedure EnsureAutoStart;
var
  err: Pointer;
begin
  if SMAppServiceAvailable then
  begin
    if SMEnabledStatus(objc_msgSend_int(SMService, sel_getUid('status'))) then
      Exit;
    err := nil;
    objc_msgSend_err(SMService, sel_getUid('registerAndReturnError:'), @err);
    // SMAppService refuses unsigned bundles ("code object is not signed at
    // all" dev builds): fall through to the legacy plist so the toggle still
    // works. Signed release builds register cleanly and never get here.
    if err = nil then
      Exit;
  end;
  if (AutoStartPath <> '') and AutoStartPathMatches then
    Exit;
  if not LegacyWriteAutoStartFile then
    ShowAutoStartFailHint;
end;

function IsAutoStartEnabled: Boolean;
begin
  if SMAppServiceAvailable then
  begin
    Result := SMEnabledStatus(objc_msgSend_int(SMService, sel_getUid('status')));
    if Result then
      Exit;
    // Registration may have fallen back to the legacy plist (unsigned app).
    Result := FileExists(AutoStartPath);
    Exit;
  end;
  Result := FileExists(AutoStartPath);
end;

procedure DisableAutoStart;
var
  err: Pointer;
begin
  if SMAppServiceAvailable then
  begin
    err := nil;
    if SMEnabledStatus(objc_msgSend_int(SMService, sel_getUid('status'))) then
      objc_msgSend_err(SMService, sel_getUid('unregisterAndReturnError:'), @err);
  end;
  // Clean up the legacy plist too: it may exist alongside (unsigned dev
  // builds) or instead of the SMAppService registration.
  if FileExists(AutoStartPath) then
    DeleteFile(AutoStartPath);
end;

end.
