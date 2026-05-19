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

function Find-LocalQuickLookInstaller {
    # Same trick as the .qlplugin auto-detection - when this script
    # ships next to a bundled QuickLook-X.Y.Z.exe (Setup.exe path), we
    # use that local file and skip the network. Avoids a second
    # SmartScreen prompt, makes the install offline-capable, and means
    # the user sees no "Downloading 60 MB..." pause.
    $scriptDir = Split-Path -Parent $PSCommandPath
    if (-not $scriptDir) { return $null }
    $candidates = Get-ChildItem -Path $scriptDir -Filter "QuickLook-*.exe" -File -ErrorAction SilentlyContinue
    if ($candidates -and $candidates.Count -gt 0) {
        return $candidates[0].FullName
    }
    return $null
}

function Install-QuickLookHost {
    Write-Step "Installing QL-Win (QuickLook) host..."

    $installer = Find-LocalQuickLookInstaller
    if ($installer) {
        Write-Host "  Using bundled QuickLook installer: $installer"
    } else {
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
    }

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

    # When the script runs under Setup.exe (cmd is hidden, stdout
    # captured to a log file) the spinner is just noise - one
    # "Working..." message and a -Wait is plenty. When run from a
    # visible cmd (manual install.bat / one-liner), keep the spinner
    # so the user can tell we're alive.
    if ($env:QLP_SETUP_EXE -eq "1") {
        $proc.WaitForExit()
    } else {
        $spinner = @('|', '/', '-', '\')
        $i = 0
        $startedAt = Get-Date
        while (-not $proc.HasExited) {
            $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
            Write-Host -NoNewline "`r  Working $($spinner[$i % 4])  ($elapsed s)   "
            $i++
            Start-Sleep -Milliseconds 250
        }
        $proc.WaitForExit()
    }
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

function Register-AddRemoveProgramsEntry {
    # Write the per-user Uninstall key so QuickLookProtein appears in
    # Settings > Apps > Installed apps and the legacy Add/Remove
    # Programs control panel. Per-user (HKCU) so no admin needed.
    #
    # The UninstallString points at a small uninstall.ps1 we drop
    # alongside the Settings app; install.ps1 itself isn't reliable
    # as an uninstaller because it can be wiped between install and
    # uninstall.
    $uninstallRoot = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\QuickLookProtein"
    $appDir = Join-Path $env:LocalAppData "QuickLookProtein\Settings"
    $uninstallScript = Join-Path $appDir "uninstall.ps1"
    $iconPath = Join-Path $appDir "QuickLookProtein.Settings.exe"

    try {
        New-Item -Path $uninstallRoot -Force | Out-Null
        # DisplayName drives what users see in Settings > Apps and
        # Add/Remove Programs. Match the rebranded marketing name
        # ("QuickLookProtein2") while leaving the registry key path
        # and plugin folder name alone so existing installs upgrade
        # in place rather than orphaning the previous entry.
        Set-ItemProperty -Path $uninstallRoot -Name "DisplayName"     -Value "QuickLookProtein2"
        Set-ItemProperty -Path $uninstallRoot -Name "DisplayVersion"  -Value (Get-PluginInstalledVersion)
        Set-ItemProperty -Path $uninstallRoot -Name "Publisher"       -Value "Ariorad Moniri"
        Set-ItemProperty -Path $uninstallRoot -Name "URLInfoAbout"    -Value "https://github.com/ArioMoniri/QuickLookProtein"
        Set-ItemProperty -Path $uninstallRoot -Name "InstallLocation" -Value $appDir
        if (Test-Path $iconPath) {
            Set-ItemProperty -Path $uninstallRoot -Name "DisplayIcon" -Value $iconPath
        }
        Set-ItemProperty -Path $uninstallRoot -Name "NoModify"       -Value 1 -Type DWord
        Set-ItemProperty -Path $uninstallRoot -Name "NoRepair"       -Value 1 -Type DWord
        Set-ItemProperty -Path $uninstallRoot -Name "EstimatedSize"  -Value 3072 -Type DWord  # ~3 MB
        Set-ItemProperty -Path $uninstallRoot -Name "UninstallString" -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstallScript`""

        # Drop the uninstall.ps1 next to the Settings app. We DO NOT
        # write it inside the plugin folder because that whole tree
        # gets wiped by re-installs.
        if (Test-Path $appDir) {
            $uninstallContent = @'
# QuickLookProtein uninstaller. Per-user; no admin needed.
$ErrorActionPreference = 'SilentlyContinue'

# 1. Stop QuickLook so we can remove the plugin folder.
Get-Process -Name "QuickLook" -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_.CloseMainWindow() | Out-Null } catch { }
    Start-Sleep -Milliseconds 600
    try { $_ | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
}

# 2. Plugin folder.
$pluginDir = Join-Path $env:LocalAppData "QuickLook\plugins\QuickLookProtein"
if (Test-Path $pluginDir) { Remove-Item -Recurse -Force $pluginDir }

# 3. Thumbnail handler registry entries.
$clsid = '{B7E4A6F1-2D6E-4F58-9B1B-2E5A1F0B97A1}'
$thumbIid = '{E357FCCD-A995-4576-B01F-234630154E96}'
$extensions = @('.pdb','.ent','.pdbqt','.pqr','.cif','.mmcif','.sdf','.mol','.mol2','.xyz','.gro','.cube','.cub','.vasp','.poscar','.cdjson')
foreach ($ext in $extensions) {
    Remove-Item -Path "HKCU:\Software\Classes\$ext\ShellEx\$thumbIid" -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -Path "HKCU:\Software\Classes\CLSID\$clsid" -Recurse -Force -ErrorAction SilentlyContinue

# 4. Settings + uninstall entry.
$appDir = Join-Path $env:LocalAppData "QuickLookProtein\Settings"
$shortcut = Join-Path $env:AppData "Microsoft\Windows\Start Menu\Programs\QuickLookProtein Settings.lnk"
if (Test-Path $shortcut) { Remove-Item -Force $shortcut }
Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\QuickLookProtein" -Recurse -Force -ErrorAction SilentlyContinue

# 5. User preferences hive (optional - kept by default so re-install
#    finds them; pass -Purge to wipe it too).
param([switch]$Purge)
if ($Purge) {
    Remove-Item -Path "HKCU:\Software\QuickLookProtein" -Recurse -Force -ErrorAction SilentlyContinue
}

# 6. Settings install dir last (since it contains this script).
if (Test-Path $appDir) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -Command Start-Sleep 1; Remove-Item -Recurse -Force '$appDir'"
}

# 7. Try to restart QuickLook so other plugins still work.
$qlExe = Join-Path $env:LocalAppData "Programs\QuickLook\QuickLook.exe"
if (Test-Path $qlExe) { Start-Process -FilePath $qlExe }
'@
            Set-Content -Path $uninstallScript -Value $uninstallContent -Encoding UTF8
        }
    } catch {
        Write-Host "  Could not register Add/Remove Programs entry: $($_.Exception.Message)"
    }
}

function Get-PluginInstalledVersion {
    # Read the plugin DLL's file version so the Uninstall key shows
    # the right number in Settings > Apps. Fall back to "1.0.0.0"
    # if we can't read it.
    try {
        $dll = Join-Path $pluginDir "QuickLook.Plugin.Protein.dll"
        if (Test-Path $dll) {
            $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dll)
            if ($vi.FileVersion) { return $vi.FileVersion }
        }
    } catch { }
    return "1.0.0.0"
}

function Install-SettingsApp {
    # Look for the Settings WPF app + dependencies in the script's
    # own folder (the Setup.exe payload puts everything alongside
    # install.ps1 + install.bat + the .qlplugin). If present, copy
    # to a stable per-user location and write a Start Menu shortcut
    # so the user can launch "QuickLookProtein Settings" the normal
    # Windows way.
    $scriptDir = Split-Path -Parent $PSCommandPath
    $settingsExe = Join-Path $scriptDir "QuickLookProtein.Settings.exe"
    if (-not (Test-Path $settingsExe)) {
        Write-Host "  Settings app not bundled - skipping shortcut install."
        return
    }

    Write-Step "Installing Settings app..."

    $appDir = Join-Path $env:LocalAppData "QuickLookProtein\Settings"
    if (Test-Path $appDir) {
        Remove-Item -Recurse -Force $appDir
    }
    New-Item -ItemType Directory -Force -Path $appDir | Out-Null

    # Copy the WPF app plus every sibling DLL / .config in the
    # script folder that doesn't belong to the plugin (the plugin
    # files are referenced from the .qlplugin's own folder by
    # QL-Win - we don't want duplicates).
    #
    # IMPORTANT: Microsoft.Web.WebView2.* and WebView2Loader.dll are
    # *required* by Settings.exe - MainWindow.xaml references the
    # <wv2:WebView2> control via
    #   xmlns:wv2="clr-namespace:Microsoft.Web.WebView2.Wpf;
    #             assembly=Microsoft.Web.WebView2.Wpf"
    # so the XAML parser resolves that assembly at InitializeComponent
    # time, *before* the window paints. Excluding those DLLs (as a
    # previous revision of this script did) makes Settings.exe throw
    # XamlParseException on launch and exit immediately, which to the
    # user looks like an "infinite respawn" if they click the Start
    # Menu shortcut repeatedly. Keep them in.
    $exclude = @(
        "QuickLookProtein.qlplugin",
        "install.bat", "install.ps1", "README.txt"
    )
    Get-ChildItem -Path $scriptDir -File | Where-Object {
        ($_.Extension -in ".exe", ".dll", ".config") -and
        ($exclude -notcontains $_.Name) -and
        ($_.Name -notlike "QuickLook-*.exe") -and
        ($_.Name -notlike "QuickLook.Plugin.*") -and
        ($_.Name -notlike "QuickLookProtein.Thumbnail.dll")
    } | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $appDir -Force
    }
    # WebView2Loader.dll lives under runtimes\win-x64\native\ in the
    # NuGet package on .NET Framework - if the build target promoted
    # it next to the .exe (CopyWebView2LoaderNative target) it'll
    # have been copied above; if not, look for it in a runtimes\
    # subdir alongside the script and lift it up.
    $loaderNative = Join-Path $scriptDir "runtimes\win-x64\native\WebView2Loader.dll"
    if ((Test-Path $loaderNative) -and -not (Test-Path (Join-Path $appDir "WebView2Loader.dll"))) {
        Copy-Item -Path $loaderNative -Destination $appDir -Force
    }
    if (-not (Test-Path (Join-Path $appDir "QuickLookProtein.Settings.exe"))) {
        Write-Host "  Settings app didn't land where expected - skipping shortcut."
        return
    }

    # SampleAssets/ subfolder feeds the Settings app's live-preview
    # tiles. Without it, every format button shows "Sample files
    # not bundled with this build." in the Settings UI.
    $sampleSrc = Join-Path $scriptDir "SampleAssets"
    if (Test-Path $sampleSrc) {
        Copy-Item -Path $sampleSrc -Destination $appDir -Recurse -Force
    } else {
        Write-Host "  Note: SampleAssets folder not in source dir; preview tiles will be unavailable."
    }

    # Start Menu shortcut. Per-user (no admin needed).
    $startMenu = Join-Path $env:AppData "Microsoft\Windows\Start Menu\Programs"
    $shortcut  = Join-Path $startMenu "QuickLookProtein Settings.lnk"
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut($shortcut)
        $lnk.TargetPath = Join-Path $appDir "QuickLookProtein.Settings.exe"
        $lnk.WorkingDirectory = $appDir
        $lnk.Description = "Configure QuickLookProtein preview settings"
        $lnk.Save()
        Write-Host "  Start Menu shortcut created: $shortcut"
    } catch {
        Write-Host "  Could not create Start Menu shortcut: $($_.Exception.Message)"
    }
}

function Register-ThumbnailHandler {
    # Install the Windows Explorer thumbnail handler if the DLL is
    # present in the plugin folder (Setup.exe / installer zip /
    # one-liner all drop QuickLookProtein.Thumbnail.dll there at the
    # same time as the .qlplugin contents).
    #
    # Registration is per-user under HKCU so we don't need admin.
    # Each supported extension gets a shell-handler key pointing at
    # our COM CLSID; the CLSID itself is registered with an
    # InProcServer32 entry pointing at the DLL.
    $thumbDll = Join-Path $pluginDir "QuickLookProtein.Thumbnail.dll"
    if (-not (Test-Path $thumbDll)) {
        Write-Host "  Thumbnail DLL not found at $thumbDll - skipping shell-handler registration."
        return
    }

    Write-Step "Registering Explorer thumbnail handler..."

    # Stable values - DO NOT change these between releases without
    # also updating ThumbnailProvider.cs's [Guid] attribute.
    $clsid     = "{B7E4A6F1-2D6E-4F58-9B1B-2E5A1F0B97A1}"
    $thumbIid  = "{E357FCCD-A995-4576-B01F-234630154E96}"
    # NOTE: .mmtf is intentionally NOT registered here. MMTF is a
    # binary MessagePack format and parsing it requires either the
    # MessagePack-CSharp NuGet (~500 KB shipped into every thumbnail
    # cache process) or ~300 LoC of hand-rolled parser. The Space-bar
    # QuickLook preview still handles .mmtf via 3Dmol.js's JS-side
    # parser; only thumbnails skip it.
    $extensions = @(".pdb", ".ent", ".pdbqt", ".pqr", ".cif", ".mmcif",
                    ".sdf", ".mol", ".mol2", ".xyz", ".gro",
                    ".cube", ".cub", ".vasp", ".poscar", ".cdjson")

    # 1) Register the CLSID -> InProcServer32 (= our DLL).
    #    mscoree.dll is the .NET Framework COM bridge; ThreadingModel
    #    Both is the standard for managed in-proc COM servers.
    $clsidKey = "HKCU:\Software\Classes\CLSID\$clsid"
    New-Item -Path "$clsidKey"               -Force | Out-Null
    Set-ItemProperty -Path "$clsidKey" -Name "(Default)" -Value "QuickLookProtein Thumbnail Provider"
    Set-ItemProperty -Path "$clsidKey" -Name "DisableProcessIsolation" -Value 1 -Type DWord

    # Resolve the actual assembly name / version / culture / public-
    # key-token from the DLL on disk so the InProcServer32\Assembly
    # value matches exactly what mscoree's CLR loader will see. Hard-
    # coding "Version=0.0.0.0" worked until v1.7.13 when MSBuild
    # started emitting Version=1.0.0.0 by default - the registry
    # value drifted out of sync and Explorer couldn't bind to the
    # type. Reading from the DLL keeps this in lock-step regardless
    # of csproj changes.
    try {
        $asmName = [System.Reflection.AssemblyName]::GetAssemblyName($thumbDll)
        $asmFullName = $asmName.FullName
    } catch {
        # Last-ditch fallback. If GetAssemblyName fails the DLL is
        # corrupt or not a .NET assembly anyway, but at least leave
        # a registry entry that documents what we tried.
        $asmFullName = "QuickLookProtein.Thumbnail, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null"
    }

    $inproc = "$clsidKey\InProcServer32"
    New-Item -Path $inproc -Force | Out-Null
    Set-ItemProperty -Path $inproc -Name "(Default)"      -Value "mscoree.dll"
    Set-ItemProperty -Path $inproc -Name "ThreadingModel" -Value "Both"
    Set-ItemProperty -Path $inproc -Name "Class"          -Value "QuickLookProtein.Thumbnail.MoleculeThumbnailProvider"
    Set-ItemProperty -Path $inproc -Name "Assembly"       -Value $asmFullName
    Set-ItemProperty -Path $inproc -Name "RuntimeVersion" -Value "v4.0.30319"
    Set-ItemProperty -Path $inproc -Name "CodeBase"       -Value ("file:///" + ($thumbDll -replace '\\','/'))

    # 2) Per-extension shell-handler key. The default value under
    #    HKCU\Software\Classes\<ext>\ShellEx\<IThumbnailProvider IID>
    #    points at our CLSID; Explorer picks it up on next icon-cache
    #    refresh.
    foreach ($ext in $extensions) {
        $shellExKey = "HKCU:\Software\Classes\$ext\ShellEx\$thumbIid"
        New-Item -Path $shellExKey -Force | Out-Null
        Set-ItemProperty -Path $shellExKey -Name "(Default)" -Value $clsid
    }

    Write-Host "  Registered $($extensions.Count) extensions to CLSID $clsid."

    # 3) Nudge Explorer to invalidate cached thumbnails for those
    #    extensions. ClearIconCache is the documented way; a hard
    #    Explorer restart is the only fully reliable way but we
    #    don't want to do that without asking - it's disruptive.
    try {
        & "$env:WinDir\system32\ie4uinit.exe" "-ClearIconCache" 2>$null | Out-Null
        Write-Host "  Cleared Explorer icon cache (existing files may take a moment to refresh)."
    } catch {
        Write-Host "  (Icon cache clear failed - thumbnails will refresh as Explorer revisits files.)"
    }
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

# Best-effort: install the Settings WPF app + Start Menu shortcut.
$wasFirstInstall = -not (Test-Path (Join-Path $env:LocalAppData "QuickLookProtein\Settings\QuickLookProtein.Settings.exe"))
try { Install-SettingsApp } catch {
    Write-Host ""
    Write-Host "  Could not install Settings app: $($_.Exception.Message)"
    Write-Host "  Plugin and thumbnails will still work."
}

# Add/Remove Programs entry so the app shows up in Settings > Apps
# and gets a proper uninstall path. Best-effort - registry writes
# can fail for various reasons (locked profile, antivirus) but the
# functional install above doesn't depend on it.
try { Register-AddRemoveProgramsEntry } catch {
    Write-Host "  Could not register Add/Remove Programs entry: $($_.Exception.Message)"
}

# Best-effort: register the Windows Explorer thumbnail handler. Same
# rule as the QuickLook restart - never fail the install over this.
# A missing thumbnail DLL just means no thumbnails in Explorer; the
# Space-bar QuickLook preview still works.
try { Register-ThumbnailHandler } catch {
    Write-Host ""
    Write-Host "  Could not register Explorer thumbnail handler: $($_.Exception.Message)"
    Write-Host "  Space-bar QuickLook preview will still work."
}

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

# Launch the Settings app on a fresh install so the user immediately
# sees the control panel and the file-format preview tiles. Upgrades
# stay quiet so a `gh release download` -> re-run doesn't keep
# popping windows.
if ($wasFirstInstall) {
    $settingsExe = Join-Path $env:LocalAppData "QuickLookProtein\Settings\QuickLookProtein.Settings.exe"
    if (Test-Path $settingsExe) {
        Write-Host "Opening QuickLookProtein Settings..."
        try { Start-Process -FilePath $settingsExe } catch {
            Write-Host "  Could not launch Settings: $($_.Exception.Message)"
        }
    }
}
