@echo off
REM ============================================================
REM QuickLookProtein - Windows installer (double-click wrapper)
REM
REM Hands off to install.ps1 in the same folder. PowerShell's
REM execution policy is bypassed for THIS process only so the
REM user doesn't have to fiddle with `Set-ExecutionPolicy`
REM beforehand.
REM
REM The companion install.ps1 will:
REM   1. Install QL-Win (QuickLook) if it isn't already there.
REM   2. Detect a sibling QuickLookProtein*.qlplugin (offline
REM      bundle case) and use it; otherwise fetch the latest
REM      one from GitHub Releases.
REM   3. Drop it into %LocalAppData%\QuickLook\plugins\.
REM   4. Restart the QuickLook tray app.
REM ============================================================

setlocal
title QuickLookProtein installer

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

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set RC=%ERRORLEVEL%

echo.
if "%RC%"=="0" (
    echo Done. Press SPACE on a .pdb / .cif / .sdf / .mol2 / .xyz
    echo file in Explorer to preview it.
) else (
    echo Installer exited with error code %RC%.
)
echo.
pause
endlocal
