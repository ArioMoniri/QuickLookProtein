# QuickLookProtein - one-line Windows installer.
#
# Run from PowerShell (any modern version, no admin required for the per-user
# plugin path):
#
#     irm https://raw.githubusercontent.com/ArioMoniri/QuickLookProtein/feature/ario-signed/Windows/install.ps1 | iex
#
# What it does, in order:
#   1. Detect whether QL-Win (https://github.com/QL-Win/QuickLook) is installed.
#      If not, fetch the latest signed QuickLook installer .exe from their
#      releases and run it silently. (User gets a SmartScreen prompt because
#      we never bundle a different binary - this is QL-Win's own installer.)
#   2. Fetch the latest QuickLookProtein-X.Y.Z.qlplugin from our own GitHub
#      release.
#   3. Treat the .qlplugin as a zip (it is) and extract it into
#      %LocalAppData%\QuickLook\plugins\QuickLookProtein\ - the per-user
#      plugin folder QL-Win scans on startup. No admin rights needed.
#   4. Restart QuickLook if it's already running so the new plugin is picked
#      up without the user having to right-click the tray icon.
#
# Safe to re-run: each step is idempotent. An existing QL-Win install is
# left alone; an existing plugin folder is overwritten so upgrades work.
#
# To uninstall:  delete  %LocalAppData%\QuickLook\plugins\QuickLookProtein

[CmdletBinding()]
param(
    # Pin to a specific QuickLookProtein release tag for reproducible
    # installs. Default is "latest" - resolves at runtime to whatever the
    # GitHub /releases/latest endpoint returns.
    [string]$Version = "latest",
    # Skip the QL-Win bootstrap even if the host isn't installed. Useful
    # when running the installer in headless contexts where you want to
    # fail loud if QL-Win is missing rather than fetch a multi-MB host.
    [switch]$SkipQuickLookInstall,
    # Path to a local .qlplugin file. When set we skip the GitHub fetch
    # and install this file. The offline-bundle .bat wrapper relies on
    # this: it ships a sibling QuickLookProtein.qlplugin and tells the
    # script to use it. If unset and a sibling .qlplugin lives next to
    # the script (typical for the downloadable installer zip), we
    # auto-detect it below.
    [string]$LocalPlugin = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"   # makes Invoke-WebRequest fast

$repoOwner   = "ArioMoniri"
$repoName    = "QuickLookProtein"
$pluginName  = "QuickLookProtein"
$pluginDir   = Join-Path $env:LocalAppData "QuickLook\plugins\$pluginName"
$tempRoot    = Join-Path $env:TEMP "QuickLookProtein-install"

function Write-Step($message) {
    Write-Host ""
    Write-Host "==> $message" -ForegroundColor Cyan
}

function Test-QuickLookInstalled {
    # QL-Win installs to %LocalAppData%\Programs\QuickLook by default, but
    # newer installers can also land in Program Files. Look in both places
    # and fall back to whether the process is running.
    $candidates = @(
        (Join-Path $env:LocalAppData "Programs\QuickLook\QuickLook.exe"),
        (Join-Path ${env:ProgramFiles} "QuickLook\QuickLook.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "QuickLook\QuickLook.exe")
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) { return $true }
    }
    return [bool](Get-Process -Name "QuickLook" -ErrorAction SilentlyContinue)
}

function Install-QuickLookHost {
    Write-Step "Installing QL-Win (QuickLook) host..."
    $api = "https://api.github.com/repos/QL-Win/QuickLook/releases/latest"
    $rel = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "QLProtein-installer" }
    $exe = $rel.assets | Where-Object { $_.name -like "QuickLook-*.exe" } | Select-Object -First 1
    if (-not $exe) {
        throw "Couldn't find a QuickLook installer .exe in the latest QL-Win release."
    }
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    $installer = Join-Path $tempRoot $exe.name
    Write-Host "  Downloading $($exe.name) ($([math]::Round($exe.size / 1MB, 1)) MB)..."
    Invoke-WebRequest -Uri $exe.browser_download_url -OutFile $installer

    # Run the QL-Win installer in fully-silent mode.
    #  /VERYSILENT          - no wizard UI, no progress bar
    #  /SUPPRESSMSGBOXES    - skip "Restart needed" / "Already running" dialogs
    #  /NORESTART           - never reboot the user's machine
    #  /CLOSEAPPLICATIONS   - if an old QuickLook is running, close it
    #  /TASKS=startup       - register QL-Win to launch at sign-in
    # Previously we used /SILENT which still shows a progress dialog;
    # the user reported the install appearing to hang because the
    # progress window can land behind our cmd console. VERYSILENT
    # removes that ambiguity at the cost of no visual feedback during
    # the install itself - we counter that below with a polling
    # spinner so the user can see we're still alive.
    Write-Host "  Launching silent installer (this can take 30-60 seconds)..."
    $proc = Start-Process -FilePath $installer `
        -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CLOSEAPPLICATIONS" `
        -PassThru

    $spinner = @('|', '/', '-', '\')
    $i = 0
    $startedAt = Get-Date
    while (-not $proc.HasExited) {
        $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
        Write-Host -NoNewline "`r  Working $($spinner[$i % 4])  ($elapsed s)   "
        $i++
        Start-Sleep -Milliseconds 250
    }
    # WaitForExit() is a no-op here (HasExited is already true) but
    # guarantees ExitCode is populated before we read it.
    $proc.WaitForExit()
    Write-Host "`r  QL-Win install finished (exit code $($proc.ExitCode)).                "
    if ($proc.ExitCode -ne 0) {
        throw "QuickLook installer returned a non-zero exit code ($($proc.ExitCode))."
    }
}

function Get-PluginReleaseAsset {
    if ($Version -eq "latest") {
        $api = "https://api.github.com/repos/$repoOwner/$repoName/releases/latest"
    } else {
        $api = "https://api.github.com/repos/$repoOwner/$repoName/releases/tags/$Version"
    }
    $rel = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "QLProtein-installer" }
    $asset = $rel.assets | Where-Object { $_.name -like "*.qlplugin" } | Select-Object -First 1
    if (-not $asset) {
        throw "No .qlplugin asset found in release $($rel.tag_name). Check https://github.com/$repoOwner/$repoName/releases."
    }
    return @{ Asset = $asset; Tag = $rel.tag_name }
}

function Resolve-LocalPluginPath {
    if (-not [string]::IsNullOrWhiteSpace($LocalPlugin)) {
        if (-not (Test-Path $LocalPlugin)) {
            throw "-LocalPlugin '$LocalPlugin' does not exist."
        }
        return (Resolve-Path $LocalPlugin).Path
    }
    # Auto-detect: when this script ships inside the offline-bundle zip,
    # the .qlplugin sits alongside it. Prefer that over fetching from GitHub.
    $scriptDir = Split-Path -Parent $PSCommandPath
    if (-not $scriptDir) { return $null }
    $candidates = Get-ChildItem -Path $scriptDir -Filter "QuickLookProtein*.qlplugin" -File -ErrorAction SilentlyContinue
    if ($candidates -and $candidates.Count -gt 0) {
        return $candidates[0].FullName
    }
    return $null
}

function Install-Plugin {
    $local = Resolve-LocalPluginPath
    if ($local) {
        Write-Step "Using local plugin file"
        Write-Host "  Source: $local"
        $pluginPath = $local
    } else {
        Write-Step "Fetching QuickLookProtein plugin..."
        $r = Get-PluginReleaseAsset
        $asset = $r.Asset
        Write-Host "  Found $($asset.name) from release $($r.Tag)."

        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        $pluginPath = Join-Path $tempRoot $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $pluginPath
    }

    Write-Step "Installing plugin to $pluginDir"
    if (Test-Path $pluginDir) {
        Remove-Item -Recurse -Force $pluginDir
    }
    New-Item -ItemType Directory -Force -Path $pluginDir | Out-Null

    # .qlplugin is a zip - Expand-Archive accepts any extension provided
    # we hand it a .zip-shaped temp copy. (Expand-Archive in older Windows
    # PowerShell refuses anything not literally named *.zip.)
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    $tmpZip = Join-Path $tempRoot "QuickLookProtein-install.zip"
    Copy-Item $pluginPath $tmpZip -Force
    Expand-Archive -Path $tmpZip -DestinationPath $pluginDir -Force
    Remove-Item $tmpZip -Force

    # Sanity check - if the .dll didn't land, the plugin won't load
    # and the user won't get any preview when they hit Space. Surface
    # the failure loudly rather than letting it slip through.
    $expected = Join-Path $pluginDir "QuickLook.Plugin.Protein.dll"
    if (-not (Test-Path $expected)) {
        Write-Host "  WARNING: $expected was not extracted. Plugin folder contents:"
        Get-ChildItem $pluginDir | ForEach-Object { Write-Host "    $($_.Name)" }
    } else {
        Write-Host "  Plugin installed: $expected"
    }
}

function Find-QuickLookExePath {
    # Search the standard QL-Win install locations. /VERYSILENT with
    # PrivilegesRequired=lowest (QL-Win's default) drops the binary
    # under %LocalAppData%\Programs\QuickLook\ on most modern boxes,
    # but per-machine installs (older builds, admin-elevated runs)
    # can land in Program Files. We check all three.
    $candidates = @(
        (Join-Path $env:LocalAppData "Programs\QuickLook\QuickLook.exe"),
        (Join-Path ${env:ProgramFiles} "QuickLook\QuickLook.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "QuickLook\QuickLook.exe")
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

function Try-StopQuickLook {
    # Returns $true if QuickLook is no longer running after this call.
    # Walks through three increasingly forceful strategies, swallows
    # the access-denied / not-found exceptions each one can throw, and
    # caller treats failure as "can't kill, ask user to restart".
    param([System.Diagnostics.Process[]]$Processes)

    # 1. Graceful WM_CLOSE. QL-Win handles this cleanly and writes its
    #    settings to disk on the way out. Doesn't need elevation.
    foreach ($p in $Processes) {
        try { [void]$p.CloseMainWindow() } catch { }
    }
    Start-Sleep -Milliseconds 800
    if (-not (Get-Process -Name "QuickLook" -ErrorAction SilentlyContinue)) {
        return $true
    }

    # 2. Stop-Process -Force. Works if QuickLook is at the same
    #    integrity level as our PowerShell. Fails with Access Denied
    #    when QL-Win was originally launched elevated and we're running
    #    unelevated (the user's screenshot was this case).
    try {
        $Processes | Stop-Process -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Name "QuickLook" -ErrorAction SilentlyContinue)) {
            return $true
        }
    } catch { }

    # 3. taskkill /F /IM. Same permission model as Stop-Process, but
    #    occasionally succeeds where Stop-Process fails because it
    #    uses the Win32 OpenProcess+TerminateProcess pair differently.
    try {
        & taskkill.exe /F /IM "QuickLook.exe" /T 2>$null | Out-Null
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Name "QuickLook" -ErrorAction SilentlyContinue)) {
            return $true
        }
    } catch { }

    return $false
}

function Restart-QuickLookHost {
    # Active goal: have QuickLook running (with our plugin loaded) by
    # the time this function returns. NEVER fail the install if we
    # can't restart - the plugin is already on disk, and QL-Win will
    # load it on its next manual restart. We just print clear
    # instructions in that case.

    $exePath = $null
    $proc = Get-Process -Name "QuickLook" -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Step "Restarting QuickLook to pick up the new plugin..."
        $exePath = $proc[0].Path
        if (-not (Try-StopQuickLook -Processes $proc)) {
            Write-Host "  Could not stop the running QuickLook process (Access Denied -"
            Write-Host "  usually means QL-Win was launched elevated and this installer"
            Write-Host "  is running unelevated)."
            Write-Host ""
            Write-Host "  PLUGIN IS INSTALLED. To load it, right-click the QuickLook"
            Write-Host "  tray icon -> 'Exit', then re-launch QuickLook from the Start"
            Write-Host "  Menu. Or sign out + back in. Or reboot."
            return
        }
        # cfprefsd-style: give the OS a beat to release the executable
        # lock before relaunching, otherwise the new process can race
        # the old one and fail.
        Start-Sleep -Seconds 1
    } else {
        Write-Step "Starting QuickLook (first-time launch)..."
        $exePath = Find-QuickLookExePath
    }

    if ($exePath -and (Test-Path $exePath)) {
        try {
            Start-Process -FilePath $exePath
        } catch {
            Write-Host "  Could not launch ${exePath}: $($_.Exception.Message)"
            Write-Host "  The plugin is in place - launch QuickLook from the Start Menu."
            return
        }
        Start-Sleep -Seconds 2
        if (Get-Process -Name "QuickLook" -ErrorAction SilentlyContinue) {
            Write-Host "  QuickLook is running. Press SPACE on a supported file in Explorer."
        } else {
            Write-Host "  WARNING: launched $exePath but QuickLook isn't showing up in the process list yet."
            Write-Host "  Give it a moment, or start it manually from the Start Menu."
        }
    } else {
        Write-Host "  WARNING: could not find QuickLook.exe under %LocalAppData%\Programs\QuickLook\,"
        Write-Host "  Program Files\QuickLook\, or Program Files (x86)\QuickLook\."
        Write-Host "  Launch QuickLook manually from the Start Menu - the plugin is already in place."
    }
}

Write-Host ""
Write-Host "QuickLookProtein - Windows installer" -ForegroundColor Green
Write-Host "Plugin folder: $pluginDir"

if (-not (Test-QuickLookInstalled)) {
    if ($SkipQuickLookInstall) {
        throw "QL-Win (QuickLook) is not installed and -SkipQuickLookInstall was passed. Install QuickLook first: https://github.com/QL-Win/QuickLook/releases/latest"
    }
    Install-QuickLookHost
} else {
    Write-Host "QL-Win (QuickLook) is already installed - skipping host bootstrap."
}

Install-Plugin

# The plugin is now on disk - that's the install. Restarting
# QuickLook is just the convenience step that picks it up
# immediately. If it fails (Access Denied from an elevated daemon,
# QuickLook.exe not where we expect, AV blocking Start-Process,
# etc.) we surface a warning but DO NOT fail the install: the user
# can restart QuickLook themselves and the plugin will load fine.
try {
    Restart-QuickLookHost
} catch {
    Write-Host ""
    Write-Host "  Plugin install succeeded, but the QuickLook restart step hit an error:"
    Write-Host "  $($_.Exception.Message)"
    Write-Host "  Restart QuickLook manually (tray icon -> Exit, then re-launch from"
    Write-Host "  the Start Menu) - the plugin is already in place and will load."
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Hit <Space> on a .pdb / .cif / .sdf / .mol / .mol2 / .xyz / .gro / .cube / .pqr / .vasp / .cdjson / .mmtf file in Explorer."
Write-Host ""
