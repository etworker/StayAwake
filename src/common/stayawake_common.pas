unit stayawake_common;

{$mode objfpc}{$H+}

interface

const
  APP_NAME = 'StayAwake';
  APP_VERSION = '0.2.0';
  INTERVAL_SECS = 60;
  ICON_SIZE = 32;

type
  TIconPixels = array[0 .. (ICON_SIZE * ICON_SIZE * 4) - 1] of Byte;

var
  AppActive: Boolean;

// Draw the tray/icon artwork into a caller-supplied RGBA buffer of
// Size x Size. Shared by the runtime trays (Size = ICON_SIZE, macOS uses 36)
// and tools/gen_icon.pas so the two can never drift apart.
//
// The artwork is an eye, matching the app's purpose of keeping the machine
// awake: open eye = actively preventing sleep, closed eye (with lashes) =
// paused so the system sleeps normally. Both states are single-color shapes
// on transparency, so macOS can also render them as a template image that
// adapts to the menu-bar appearance.
procedure GenerateIconPixels(Size: Integer; Active: Boolean; Pixels: PByte);

// Convenience wrapper for the fixed-size tray icon.
procedure GenerateTrayIconPixels(Active: Boolean; var Pixels: TIconPixels);

// Tiny one-value config store shared by the tray UI and background logic
// (language choice, lid-close mode). First line of the file is the value;
// any I/O problem leaves the default in place.
function ReadConfigValue(FileName, DefValue: string): string;
procedure WriteConfigValue(FileName, Value: string);

implementation

uses
  SysUtils,
  Classes;

procedure GenerateIconPixels(Size: Integer; Active: Boolean; Pixels: PByte);
const
  SS = 3; // supersampling grid per pixel axis (3x3 = 9 samples)
var
  x, y, sx, sy, idx, inside: Integer;
  u, v, dx, dy, yEdge, dIris, dist, shade: Double;
  cr, cg, cb: Double;
  cov: Double;
  // closed-eye geometry
  lx0, ly0, lx1, ly1, segLen, tSeg, dSeg, tLash: Double;
  lashX, signX: Double;
  li: Integer;
begin
  for y := 0 to Size - 1 do
  begin
    for x := 0 to Size - 1 do
    begin
      idx := (y * Size + x) * 4;
      inside := 0;
      cr := 0; cg := 0; cb := 0;
      for sy := 0 to SS - 1 do
      begin
        for sx := 0 to SS - 1 do
        begin
          u := (x + (sx + 0.5) / SS) / Size;
          v := (y + (sy + 0.5) / SS) / Size;
          dx := Abs(u - 0.5);
          dy := v - 0.5;
          cov := 0;
          if Active then
          begin
            // Open eye: almond outline (two arcs meeting at the corners)
            // plus a solid iris. 0.5 +- band around the lens boundary.
            if dx <= 0.40 then
            begin
              yEdge := 0.21 * Sqrt(1.0 - Sqr(dx / 0.40));
              if Abs(Abs(dy) - yEdge) <= 0.0275 then
                cov := 1
              // Iris disc, kept clear of the outline band.
              else if (Sqr(dx) + Sqr(dy) <= Sqr(0.135)) and
                      (Abs(dy) < yEdge - 0.0275) then
                cov := 1;
            end;
            if cov > 0 then
            begin
              dist := Sqrt(Sqr(dx) + Sqr(dy));
              shade := dist / 0.40;
              if shade > 1 then
                shade := 1;
              cr := cr + (110.0 - 70.0 * shade);
              cg := cg + (220.0 - 70.0 * shade);
              cb := cb + (150.0 - 60.0 * shade);
            end;
          end
          else
          begin
            // Closed eye: a downward-curving lid line plus three lashes.
            if dx <= 0.34 then
            begin
              yEdge := 0.03 + 0.135 * Sqrt(1.0 - Sqr(dx / 0.34));
              if Abs(dy - yEdge) <= 0.028 then
                cov := 1;
            end;
            // Lashes: thick line segments from the lid going down/outward.
            for li := -1 to 1 do
            begin
              lashX := li * 0.16;
              if lashX = 0 then
                signX := 0
              else
                signX := lashX / Abs(lashX);
                lx0 := 0.5 + lashX;
                ly0 := 0.5 + 0.03 + 0.135 * Sqrt(1.0 - Sqr(lashX / 0.34)) + 0.02;
                lx1 := lx0 + signX * 0.11 * 0.35;
                ly1 := ly0 + 0.11;
                segLen := Sqrt(Sqr(lx1 - lx0) + Sqr(ly1 - ly0));
                tSeg := ((u - lx0) * (lx1 - lx0) + (v - ly0) * (ly1 - ly0)) / Sqr(segLen);
                if tSeg < 0 then
                  tSeg := 0;
                if tSeg > 1 then
                  tSeg := 1;
                dSeg := Sqrt(Sqr(u - (lx0 + tSeg * (lx1 - lx0))) +
                             Sqr(v - (ly0 + tSeg * (ly1 - ly0))));
                tLash := 0.022;
                if dSeg <= tLash then
                  cov := 1;
            end;
            if cov > 0 then
            begin
              cr := cr + 160.0;
              cg := cg + 160.0;
              cb := cb + 160.0;
            end;
          end;
          if cov > 0 then
            Inc(inside);
        end;
      end;
      if inside > 0 then
      begin
        cov := inside / Sqr(SS);
        Pixels[idx] := Round(cr / inside);
        Pixels[idx + 1] := Round(cg / inside);
        Pixels[idx + 2] := Round(cb / inside);
        Pixels[idx + 3] := Round(255.0 * cov);
      end
      else
      begin
        Pixels[idx] := 0;
        Pixels[idx + 1] := 0;
        Pixels[idx + 2] := 0;
        Pixels[idx + 3] := 0;
      end;
    end;
  end;
end;

procedure GenerateTrayIconPixels(Active: Boolean; var Pixels: TIconPixels);
begin
  GenerateIconPixels(ICON_SIZE, Active, @Pixels[0]);
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

end.
