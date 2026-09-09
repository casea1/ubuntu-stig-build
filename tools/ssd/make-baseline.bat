@echo off
setlocal EnableExtensions
REM ===================================================================
REM  make-baseline.bat -- build baseline.git.tar.gz on this SSD.
REM
REM  Double-click it. It fetches the current baseline from git.asplab.com
REM  and leaves two files beside itself, replacing any older copies:
REM
REM      baseline.git.tar.gz          the archive to carry
REM      baseline.git.tar.gz.sha256   its hash, to check on the far end
REM
REM  Then see docs/procedures.md 4.4d for the Linux side. The commands are
REM  printed at the end of this run too.
REM
REM  Needs Git for Windows. Packing uses Windows' own tar (10 1803+), or
REM  the tar that ships inside Git for Windows.
REM ===================================================================

REM Work beside THIS FILE, whatever drive letter the SSD gets today.
pushd "%~dp0"
if errorlevel 1 (
  echo Could not enter the script's own folder.
  pause
  exit /b 1
)

set "REPO=https://git.asplab.com/ASPLAB/ubuntu-stig-build.git"
set "BRANCH=main"
set "OUT=baseline.git.tar.gz"
set "WORK=_baseline_build"

echo.
echo   Building %OUT%
echo   from %REPO%
echo   into %CD%
echo.

REM ---- tools --------------------------------------------------------
where git >nul 2>&1
if errorlevel 1 goto :nogit

REM Find a tar. Windows 10 1803+ has one; otherwise Git for Windows ships
REM one that is not on PATH. Resolved here, at the top level -- a lookup
REM like this inside an if(...) block is where these scripts usually break:
REM the x86 Program Files variable has a closing bracket in its NAME, which
REM ends the block early on the parser's way through it.
set "TAR="
where tar >nul 2>&1
if not errorlevel 1 set "TAR=tar"
if not defined TAR if exist "%ProgramFiles%\Git\usr\bin\tar.exe" set "TAR=%ProgramFiles%\Git\usr\bin\tar.exe"
if not defined TAR if exist "%ProgramW6432%\Git\usr\bin\tar.exe" set "TAR=%ProgramW6432%\Git\usr\bin\tar.exe"
if not defined TAR if exist "%LocalAppData%\Programs\Git\usr\bin\tar.exe" set "TAR=%LocalAppData%\Programs\Git\usr\bin\tar.exe"
if not defined TAR goto :notar

REM ---- clean any wreckage from an interrupted run -------------------
if exist "%WORK%" rmdir /s /q "%WORK%"
if exist "%OUT%.tmp" del /f /q "%OUT%.tmp"
mkdir "%WORK%"
if errorlevel 1 goto :fail

REM ---- fetch --------------------------------------------------------
echo   [1/3] Cloning...
git clone --mirror --quiet "%REPO%" "%WORK%\baseline.git"
if errorlevel 1 goto :noclone

REM Confirm this is the baseline the Linux side will demand, rather than
REM shipping an archive that `it-pull load` refuses on arrival -- which you
REM would discover at the far end, in front of the box.
git -C "%WORK%\baseline.git" cat-file -e "refs/heads/%BRANCH%:local.yml" 2>nul
if errorlevel 1 goto :wrongrepo
git -C "%WORK%\baseline.git" cat-file -e "refs/heads/%BRANCH%:roles/it_scripts" 2>nul
if errorlevel 1 goto :wrongrepo

set "HEADLINE="
for /f "usebackq delims=" %%v in (`git -C "%WORK%\baseline.git" log -1 --date=short "--format=%%h  %%ad  %%s" "%BRANCH%"`) do set "HEADLINE=%%v"

REM ---- pack ---------------------------------------------------------
REM Build to .tmp and rename only on success. An interrupted run must not
REM leave a half-written archive wearing the good name: you would carry it
REM to a box and find out there.
echo   [2/3] Packing...
"%TAR%" -C "%WORK%" -czf "%OUT%.tmp" baseline.git
if errorlevel 1 goto :fail
if not exist "%OUT%.tmp" goto :fail

REM ---- replace the old one ------------------------------------------
echo   [3/3] Replacing the previous archive...
if exist "%OUT%" del /f /q "%OUT%"
if exist "%OUT%" goto :locked
move /y "%OUT%.tmp" "%OUT%" >nul
if errorlevel 1 goto :fail

rmdir /s /q "%WORK%"

REM ---- a hash to check on the far end -------------------------------
set "SHA="
for /f "usebackq skip=1 delims=" %%h in (`certutil -hashfile "%OUT%" SHA256`) do if not defined SHA set "SHA=%%h"
set "SHA=%SHA: =%"
> "%OUT%.sha256" echo %SHA%  %OUT%

echo.
echo   ==================================================================
echo    Done.  %OUT%
echo    Baseline: %HEADLINE%
echo    SHA256:   %SHA%
echo   ==================================================================
echo.
echo    On the Linux box:
echo      sha256sum ~/baseline.git.tar.gz
echo      sudo install -d -m 0700 /opt/it/baseline-stage
echo      sudo tar xzf ~/baseline.git.tar.gz -C /opt/it/baseline-stage
echo      sudo it-pull load /opt/it/baseline-stage/baseline.git
echo      sudo it-pull
echo.
popd
pause
exit /b 0

:nogit
echo   [X] git is not on PATH. Install "Git for Windows" and run this again.
echo       https://git-scm.com/download/win
goto :fail

:notar
echo   [X] No tar found. Windows 10 1803 and later include one; otherwise
echo       install Git for Windows, which ships one.
goto :fail

:noclone
echo.
echo   [X] Clone failed. Usually one of:
echo         - not on the lab network / VPN
echo         - credentials not cached. Test with:
echo             git ls-remote %REPO%
goto :fail

:wrongrepo
echo   [X] That clone is missing local.yml or roles/it_scripts on %BRANCH%.
echo       Wrong repository, or the branch name has changed.
goto :fail

:locked
echo   [X] Could not replace %OUT% -- is it open in another program?
goto :fail

:fail
echo.
echo   FAILED -- the previous %OUT% (if any) has NOT been touched.
echo.
if exist "%WORK%" rmdir /s /q "%WORK%"
if exist "%OUT%.tmp" del /f /q "%OUT%.tmp"
popd
pause
exit /b 1
