@echo off
setlocal EnableExtensions
REM ===================================================================
REM  set-vscode-pc.bat -- set VS Code up for Remote-SSH to the boxes, for
REM  EVERY user of this PC (and accounts created later). Double-click it;
REM  it asks for administrator. Run once per PC. Safe to run again.
REM
REM      set-vscode-pc.bat           apply
REM      set-vscode-pc.bat check     show what is set, change nothing
REM
REM  The work is in set-vscode-pc.ps1 -- keep the two files together.
REM ===================================================================
net session >nul 2>&1
if errorlevel 1 (
  if "%~1"=="" (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  ) else (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%~1' -Verb RunAs"
  )
  exit /b
)
pushd "%~dp0"
if not exist "set-vscode-pc.ps1" (
  echo   set-vscode-pc.ps1 must be in the same folder as this file.
  popd
  pause
  exit /b 1
)
if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "set-vscode-pc.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "set-vscode-pc.ps1" -Mode %1
)
set "RC=%ERRORLEVEL%"
popd
pause
exit /b %RC%
