@echo off
REM ============================================================
REM QuickLookProtein - Windows installer (double-click wrapper)
REM
REM Hands off to install.ps1 in the same folder. PowerShell's
REM execution policy is bypassed for THIS process only so the
REM user doesn't have to fiddle with `Set-ExecutionPolicy`
REM beforehand.
REM
REM Behaves slightly differently depending on how it's invoked:
REM
REM   * As a child of QuickLookProtein-Setup.exe (Inno Setup
REM     passes the env var QLP_SETUP_EXE=1 in [Run]):
REM       - no "press any key to start" banner;
REM     - on success, auto-close after a short delay so the
REM       parent Inno Setup wizard can advance to "Finished".
REM
REM   * Run by a human (double-click from the installer zip,
REM     or from an unzipped folder):
REM       - friendly intro + final "press any key" so they can
REM       read the result.
REM
REM Pause-then-block was the old behaviour even when invoked by
REM Setup.exe; that's why earlier versions appeared to hang at
REM "Finishing installation..." until the user noticed the
REM hidden cmd window.
REM ============================================================

setlocal
title QuickLookProtein installer

if defined QLP_SETUP_EXE goto :run

echo.
echo ============================================================
echo   QuickLookProtein - Windows installer
echo ============================================================
echo.
echo This will:
echo   - Install QuickLook (https://github.com/QL-Win/QuickLook)
echo     if it isn't already present.
echo   - Install the QuickLookProtein plugin into your user
echo     profile (no admin required).
echo   - Restart QuickLook so the plugin is picked up.
echo.
echo Press any key to start, or close this window to cancel.
pause >nul

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set RC=%ERRORLEVEL%

echo.
if "%RC%"=="0" (
    echo Done. Press SPACE on a .pdb / .cif / .sdf / .mol2 / .xyz
    echo file in Explorer to preview it.
) else (
    echo Installer exited with error code %RC%.
)

if defined QLP_SETUP_EXE (
    REM Auto-close after a brief moment so the parent Setup.exe
    REM wizard can advance to its "Finished" page. /NOBREAK
    REM prevents the user accidentally aborting early.
    echo.
    echo Closing in 5 seconds...
    timeout /t 5 /nobreak >nul
) else (
    echo.
    pause
)
endlocal
exit /b %RC%
