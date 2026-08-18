@echo off
setlocal enabledelayedexpansion

rem Build stayawake for Windows.
rem Usage: build.cmd [win32|win64]   (default: win64)
rem Set FPC to a full path to fpc.exe if it is not on PATH.
rem Output: out/windows/x86_64 (win64) or out/windows/i386 (win32),
rem mirroring the macOS layout out/macos/<arch>.

set TARGET=%~1
if "%TARGET%"=="" set TARGET=win64
if /i "%TARGET%"=="win64" (
  set BINDIR=x86_64-win64
  set OUTDIR=windows\x86_64
) else if /i "%TARGET%"=="win32" (
  set BINDIR=i386-win32
  set OUTDIR=windows\i386
) else (
  echo Usage: build.cmd [win32^|win64]
  exit /b 1
)

set ROOT=%~dp0
set SRC=%ROOT%src
set OUT=%ROOT%out\%OUTDIR%
if not exist "%OUT%\units" mkdir "%OUT%\units"

set FPC_EXE=
if defined FPC (
  set FPC_EXE=%FPC%
) else (
  for /f "delims=" %%i in ('where fpc 2^>nul') do if not defined FPC_EXE set FPC_EXE=%%i
)
if defined FPC_EXE (
  for %%i in ("!FPC_EXE!") do set FPC_ROOT=%%~dpi..\..\
  if exist "!FPC_ROOT!bin\!BINDIR!\fpc.exe" set FPC_EXE=!FPC_ROOT!bin\!BINDIR!\fpc.exe
)

if not exist "%ROOT%assets\stayawake.ico" (
  if not exist "%OUT%\tools" mkdir "%OUT%\tools"
  if defined FPC_EXE (
    "!FPC_EXE!" -Mobjfpc -O2 -FE"%OUT%\tools" -FU"%OUT%\tools" "%ROOT%tools\gen_icon.pas"
  ) else (
    fpc -Mobjfpc -O2 -FE"%OUT%\tools" -FU"%OUT%\tools" "%ROOT%tools\gen_icon.pas"
  )
  if errorlevel 1 (
    echo Icon generation failed.
    exit /b 1
  )
  "%OUT%\tools\gen_icon.exe" "%ROOT%assets\stayawake.ico"
)

pushd "%SRC%"
if defined FPC_EXE (
  "!FPC_EXE!" -Mobjfpc -O2 -Fucommon -Fuwin -FU"%OUT%\units" -FE"%OUT%" stayawake.lpr
) else (
  fpc -Mobjfpc -O2 -Fucommon -Fuwin -FU"%OUT%\units" -FE"%OUT%" stayawake.lpr
)
set RC=%errorlevel%
popd

if not "%RC%"=="0" (
  echo Build failed.
  exit /b 1
)
echo Build OK: %OUT%\stayawake.exe