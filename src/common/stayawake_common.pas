unit stayawake_common;

{$mode objfpc}{$H+}

interface

const
  APP_NAME = 'StayAwake';
  APP_VERSION = '0.1.0';
  INTERVAL_SECS = 60;
  ICON_SIZE = 32;

type
  TIconPixels = array[0 .. (ICON_SIZE * ICON_SIZE * 4) - 1] of Byte;

var
  AppActive: Boolean;
  StartActive: Boolean;

procedure GenerateIconPixels(Active: Boolean; var Pixels: TIconPixels);

implementation

procedure GenerateIconPixels(Active: Boolean; var Pixels: TIconPixels);
var
  x, y: Integer;
  dx, dy, px, py, dist, t: Double;
  r, g, b, c: Double;
  idx: Integer;
begin
  for y := 0 to ICON_SIZE - 1 do
    for x := 0 to ICON_SIZE - 1 do
    begin
      dx := x - (ICON_SIZE / 2) + 0.5;
      dy := y - (ICON_SIZE / 2) + 0.5;
      dist := Sqrt(dx * dx + dy * dy);
      idx := (y * ICON_SIZE + x) * 4;
      if dist <= (ICON_SIZE / 2) - 1.0 then
      begin
        if Active then
        begin
          t := dist / ((ICON_SIZE / 2) - 1.0);
          r := 50.0 * (1.0 - t) + 30.0;
          g := 220.0 * (1.0 - t) + 120.0;
          b := 50.0 * (1.0 - t) + 30.0;
          Pixels[idx] := Round(r);
          Pixels[idx + 1] := Round(g);
          Pixels[idx + 2] := Round(b);
          Pixels[idx + 3] := 255;
        end
        else
        begin
          px := x - (ICON_SIZE / 2) + 0.5;
          py := y - (ICON_SIZE / 2) + 0.5;
          if ((px >= -4.0) and (px <= -1.0) and (py >= -6.0) and (py <= 6.0)) or
             ((px >= 1.0) and (px <= 4.0) and (py >= -6.0) and (py <= 6.0)) then
          begin
            Pixels[idx] := 200;
            Pixels[idx + 1] := 200;
            Pixels[idx + 2] := 200;
            Pixels[idx + 3] := 255;
          end
          else
          begin
            t := dist / ((ICON_SIZE / 2) - 1.0);
            c := 100.0 * (1.0 - t) + 60.0;
            Pixels[idx] := Round(c);
            Pixels[idx + 1] := Round(c);
            Pixels[idx + 2] := Round(c);
            Pixels[idx + 3] := 255;
          end;
        end;
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

end.