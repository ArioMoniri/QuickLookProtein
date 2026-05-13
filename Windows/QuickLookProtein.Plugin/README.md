# QuickLookProtein — Windows plugin

A [QL-Win/QuickLook](https://github.com/QL-Win/QuickLook) plugin that adds 3D molecule previews to Windows Explorer. Press <kbd>Space</kbd> on a `.pdb` / `.cif` / `.sdf` / `.mol` / `.mol2` / `.xyz` / `.gro` / `.cube` / `.pqr` / `.vasp` / `.cdjson` / `.mmtf` file and a window pops up showing the rotating structure, rendered by [3Dmol.js](https://3dmol.csb.pitt.edu) inside WebView2.

The renderer is the same `3Dmol.js` and `viewer.html` that ship in the macOS app — single source of truth, edits in one place affect both platforms.

## Install

### One-liner (recommended)

```powershell
irm https://raw.githubusercontent.com/ArioMoniri/QuickLookProtein/feature/ario-signed/Windows/install.ps1 | iex
```

What it does:
1. Detects whether [QuickLook](https://github.com/QL-Win/QuickLook) is installed; if not, downloads and runs the official QL-Win installer.
2. Fetches **QuickLookProtein-X.Y.Z.qlplugin** from the [latest release](https://github.com/ArioMoniri/QuickLookProtein/releases/latest).
3. Extracts it into `%LocalAppData%\QuickLook\plugins\QuickLookProtein\` (per-user, no admin needed).
4. Restarts QuickLook so the new plugin is picked up immediately.

Re-runs upgrade in place. To uninstall, delete the plugin folder.

### Manual

1. Install [QuickLook](https://github.com/QL-Win/QuickLook/releases/latest) (free, GPL-3, the Windows-side Quick Look daemon — required host for this plugin).
2. Download **QuickLookProtein-X.Y.Z.qlplugin** from the [latest release](https://github.com/ArioMoniri/QuickLookProtein/releases/latest).
3. Either double-click the `.qlplugin` while QuickLook is running, **or** extract it into `%LocalAppData%\QuickLook\plugins\`.
4. Restart QuickLook from the system tray.
5. Hit <kbd>Space</kbd> on any supported file in Explorer.

No code-signing — Windows will show a SmartScreen warning the first time you load an unsigned plugin. Click "More info" → "Run anyway".

## Build

Requires Windows + .NET 8 SDK + a recent `QuickLook.Common.dll` extracted from a [QL-Win release](https://github.com/QL-Win/QuickLook/releases/latest):

```pwsh
# 1. Drop QuickLook.Common.dll into libs/
mkdir libs
# (extract from a QL-Win release zip and copy QuickLook.Common.dll here)

# 2. Build
dotnet build -c Release

# 3. Package as .qlplugin
Compress-Archive -Path bin/Release/net8.0-windows/* -DestinationPath QuickLookProtein.qlplugin -Force
```

The GitHub Actions release workflow does all of this automatically when you tag `vX.Y.Z` — see `.github/workflows/release.yml` for the Windows job that runs on `windows-latest`.

## Architecture

- **`Plugin.cs`** — implements QL-Win's `IViewer` interface. `CanHandle` claims the same 13 file extensions as the macOS QL extension; `View` creates a `MoleculePanel` and hands it to QL-Win's host window.
- **`MoleculePanel.xaml(.cs)`** — a WPF `UserControl` that hosts `WebView2`. Loads the shared `viewer.html` template, runs the same `{KEY}` substitutions as the macOS code path, points `<script src="3Dmol.js">` at a virtual host backed by the plugin's `Resources/` folder, and navigates the WebView there.

If you change rendering behaviour, edit `Xcode/Shared/Assets/3Dmol_viewer.html` and `Xcode/Shared/Assets/3Dmol.js` — the Windows plugin links to those exact files via its `.csproj` so changes flow to both platforms.
