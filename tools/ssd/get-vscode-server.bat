@echo off
setlocal EnableExtensions
REM ===================================================================
REM  get-vscode-server.bat -- download what an air-gapped box and its PCs
REM  need for VS Code Remote-SSH. Double-click it on a PC with internet.
REM
REM  With no argument it matches the VS Code installed on THIS PC. Or:
REM      get-vscode-server.bat 1.139.1
REM      get-vscode-server.bat COMMIT      (VS Code: Help - About)
REM      get-vscode-server.bat latest
REM
REM  Leaves a vscode-VERSION folder beside itself. README.txt inside says what
REM  to do with it. The work is in get-vscode-server.ps1 -- keep the two
REM  files together.
REM ===================================================================
pushd "%~dp0"
if not exist "get-vscode-server.ps1" (
  echo   get-vscode-server.ps1 must be in the same folder as this file.
  popd
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "get-vscode-server.ps1" %1
set "RC=%ERRORLEVEL%"
popd
pause
exit /b %RC%
