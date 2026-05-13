# QuickLookProtein — one-line Windows installer.
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
#      we never bundle a different binary — this is QL-Win's own installer.)
#   2. Fetch the latest QuickLookProtein-X.Y.Z.qlplugin from our own GitHub
#      release.
#   3. Treat the .qlplugin as a zip (it is) and extract it into
#      %LocalAppData%\QuickLook\plugins\QuickLookProtein\ — the per-user
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
    # installs. Default is "latest" — resolves at runtime to whatever the
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
    Write-Host "  Running installer (you may see a SmartScreen prompt — click 'More info' → 'Run anyway')."
    # /SILENT shows progress but skips the wizard pages; /VERYSILENT is
    # fully silent but the Inno Setup installer still occasionally pops
    # a UAC dialog for per-machine installs.
    Start-Process -FilePath $installer -ArgumentList "/SILENT" -Wait
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

    # .qlplugin is a zip — Expand-Archive accepts any extension provided
    # we hand it a .zip-shaped temp copy. (Expand-Archive in older Windows
    # PowerShell refuses anything not literally named *.zip.)
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    $tmpZip = Join-Path $tempRoot "QuickLookProtein-install.zip"
    Copy-Item $pluginPath $tmpZip -Force
    Expand-Archive -Path $tmpZip -DestinationPath $pluginDir -Force
    Remove-Item $tmpZip -Force
}

function Restart-QuickLookHost {
    $proc = Get-Process -Name "QuickLook" -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Step "Restarting QuickLook to pick up the new plugin..."
        $exePath = $proc[0].Path
        $proc | Stop-Process -Force
        Start-Sleep -Seconds 1
        if ($exePath -and (Test-Path $exePath)) {
            Start-Process -FilePath $exePath
        }
    }
}

Write-Host ""
Write-Host "QuickLookProtein — Windows installer" -ForegroundColor Green
Write-Host "Plugin folder: $pluginDir"

if (-not (Test-QuickLookInstalled)) {
    if ($SkipQuickLookInstall) {
        throw "QL-Win (QuickLook) is not installed and -SkipQuickLookInstall was passed. Install QuickLook first: https://github.com/QL-Win/QuickLook/releases/latest"
    }
    Install-QuickLookHost
} else {
    Write-Host "QL-Win (QuickLook) is already installed — skipping host bootstrap."
}

Install-Plugin
Restart-QuickLookHost

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Hit <Space> on a .pdb / .cif / .sdf / .mol / .mol2 / .xyz / .gro / .cube / .pqr / .vasp / .cdjson / .mmtf file in Explorer."
Write-Host ""
