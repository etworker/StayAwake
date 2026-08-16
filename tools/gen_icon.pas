program gen_icon;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes;

const
  Sizes: array[0..4] of Integer = (16, 32, 48, 64, 256);

procedure FillPixels(Size: Integer; Pixels: PByte);
var
  x, y: Integer;
  dx, dy, dist, t: Double;
  idx: Integer;
begin
  for y := 0 to Size - 1 do
    for x := 0 to Size - 1 do
    begin
      dx := x - (Size / 2) + 0.5;
      dy := y - (Size / 2) + 0.5;
      dist := Sqrt(dx * dx + dy * dy);
      idx := (y * Size + x) * 4;
      if dist <= (Size / 2) - 1.0 then
      begin
        t := dist / ((Size / 2) - 1.0);
        Pixels[idx] := Round(50.0 * (1.0 - t) + 30.0);
        Pixels[idx + 1] := Round(220.0 * (1.0 - t) + 120.0);
        Pixels[idx + 2] := Round(50.0 * (1.0 - t) + 30.0);
        Pixels[idx + 3] := 255;
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

procedure W2(f: TStream; v: Word);
begin
  f.WriteByte(v and $FF);
  f.WriteByte((v shr 8) and $FF);
end;

procedure W4(f: TStream; v: Cardinal);
begin
  f.WriteByte(v and $FF);
  f.WriteByte((v shr 8) and $FF);
  f.WriteByte((v shr 16) and $FF);
  f.WriteByte((v shr 24) and $FF);
end;

procedure WriteImage(f: TStream; Size: Integer; Pixels: PByte);
var
  x, y, i: Integer;
  xorLen, andLen: Cardinal;
begin
  xorLen := Size * Size * 4;
  andLen := Size * Size div 8;
  W4(f, 40);
  W4(f, Size);
  W4(f, Size * 2);
  W2(f, 1);
  W2(f, 32);
  W4(f, 0);
  W4(f, xorLen + andLen);
  W4(f, 0);
  W4(f, 0);
  W4(f, 0);
  W4(f, 0);
  for y := Size - 1 downto 0 do
    for x := 0 to Size - 1 do
    begin
      i := (y * Size + x) * 4;
      f.WriteByte(Pixels[i + 2]);
      f.WriteByte(Pixels[i + 1]);
      f.WriteByte(Pixels[i]);
      f.WriteByte(Pixels[i + 3]);
    end;
  for i := 0 to andLen - 1 do
    f.WriteByte(0);
end;

var
  fs: TFileStream;
  OutPath: string;
  i, Size: Integer;
  Pixels: array of Byte;
  Off: Cardinal;

begin
  if ParamCount >= 1 then
    OutPath := ParamStr(1)
  else
    OutPath := 'keep_awake.ico';

  fs := TFileStream.Create(OutPath, fmCreate);
  try
    W2(fs, 0);
    W2(fs, 1);
    W2(fs, Length(Sizes));
    Off := 6 + Length(Sizes) * 16;
    for i := 0 to Length(Sizes) - 1 do
    begin
      Size := Sizes[i];
      if Size >= 256 then
        fs.WriteByte(0)
      else
        fs.WriteByte(Size);
      fs.WriteByte(Size);
      fs.WriteByte(0);
      fs.WriteByte(0);
      W2(fs, 1);
      W2(fs, 32);
      W4(fs, 40 + Size * Size * 4 + Size * Size div 8);
      W4(fs, Off);
      Inc(Off, 40 + Size * Size * 4 + Size * Size div 8);
    end;
    for i := 0 to Length(Sizes) - 1 do
    begin
      Size := Sizes[i];
      SetLength(Pixels, Size * Size * 4);
      FillPixels(Size, @Pixels[0]);
      WriteImage(fs, Size, @Pixels[0]);
    end;
  finally
    fs.Free;
  end;
end.