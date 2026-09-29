@echo off
rem ============================================================
rem  nested-archive-unpacker - quick launcher
rem
rem  Usage 1: drag an archive file onto this .cmd
rem  Usage 2: double-click this file, then paste the archive path
rem
rem  NOTE: this file is intentionally ASCII-only. cmd.exe parses
rem  batch files using the OEM code page, so non-ASCII comments
rem  would be mis-decoded and break parsing. All localized output
rem  is produced by unpack-nested.ps1 instead (it carries a BOM).
rem ============================================================
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion

set "HERE=%~dp0"
set "PS1=%HERE%unpack-nested.ps1"

if not exist "%PS1%" (
  echo [X] Cannot find unpack-nested.ps1 next to this file.
  echo     Expected: %PS1%
  echo.
  pause
  exit /b 1
)

rem ---- no file dropped: ask interactively ----
if "%~1"=="" (
  echo ============================================
  echo   Nested Archive Unpacker
  echo ============================================
  echo.
  echo Drag an archive onto this .cmd file,
  echo or paste its full path below.
  echo.
  set /p "TARGET=Path: "
  if "!TARGET!"=="" (
    echo [X] Nothing provided.
    echo.
    pause
    exit /b 1
  )
  call :RUN "!TARGET!"
  echo.
  pause
  exit /b 0
)

rem ---- file(s) dropped: handle each one ----
:LOOP
if "%~1"=="" goto DONE
call :RUN "%~1"
shift
goto LOOP

:DONE
echo.
pause
exit /b 0

:RUN
echo.
echo ^>^>^> %~nx1
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" "%~f1"
exit /b 0
