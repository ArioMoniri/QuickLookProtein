@echo off
REM ============================================================
REM QuickLookProtein - Windows installer (double-click wrapper)
REM
REM Two invocation modes:
REM
REM 1. Manual (user double-clicks this from the installer zip,
REM    or from an unzipped folder): friendly intro + final "press
REM    any key" so they can read the result.
REM
REM 2. Setup.exe context (Inno Setup's [Run] sets the env var
REM    QLP_SETUP_EXE=1 and redirects stdout/stderr to a log file
REM    in %TEMP%): no intro, no pauses, exit silently. The Inno
REM    Setup wizard owns all the user-visible progress.
REM
REM Hands off to install.ps1 in the same folder. PowerShell's
REM execution policy is bypassed for THIS process only so the user
REM doesn't have to fiddle with `Set-ExecutionPolicy` beforehand.
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

if not defined QLP_SETUP_EXE (
    echo.
    if "%RC%"=="0" (
        echo Done. Press SPACE on a .pdb / .cif / .sdf / .mol2 / .xyz
        echo file in Explorer to preview it.
    ) else (
        echo Installer exited with error code %RC%.
    )
    echo.
    pause
)

endlocal
exit /b %RC%
