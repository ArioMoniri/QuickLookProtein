# Install paths

The short version is in the [README](../README.md). This file collects the alternative install paths and the implementation notes.

## 🍎 macOS

### Disk image (recommended)
Download [`QuickLookProtein.dmg`](https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein.dmg) from the latest release, open it, drag the app to `/Applications`, eject. Signed with Developer ID `FF68N39FU5` and notarised by Apple, so Gatekeeper opens it without warning.

### Zip
[`QuickLookProtein-X.Y.Z.zip`](https://github.com/ArioMoniri/QuickLookProtein/releases/latest) — unzip and drag the `.app` to `/Applications`. Same payload as the DMG, just without the disk-image wrapper.

### Homebrew
```bash
brew tap ariomoniri/quicklookprotein https://github.com/ArioMoniri/QuickLookProtein
brew install --cask quicklookprotein
```

The cask file lives at [`Casks/quicklookprotein.rb`](../Casks/quicklookprotein.rb) — audit-friendly. SHA256 is pinned per-version and auto-bumped via [`.github/workflows/cask-bump.yml`](../.github/workflows/cask-bump.yml) on every release. A submission to `homebrew/homebrew-cask` is on the punch list; until then the personal tap above is the supported path.

`brew upgrade --cask quicklookprotein` handles version bumps; Sparkle in-app updates work in between for users who don't use brew.

### From source

Open `Xcode/QuickLookProtein.xcodeproj`, build with ⌘B. Local dev builds aren't signed with the production EDDSA key, so Sparkle auto-updates are disabled (the Software Update panel falls back to a "Download from GitHub" button).

## 🪟 Windows

QuickLookProtein2 is a plugin for [**QuickLook**](https://github.com/QL-Win/QuickLook) (QL-Win) — a free Space-bar previewer for Windows Explorer. You need QuickLook installed before our plugin can do anything.

### Recommended: Microsoft Store + our Setup.exe

1. Install QuickLook from the [Microsoft Store](https://apps.microsoft.com/detail/9NV4BS3L1H4S). It's signed by Microsoft, auto-updates, and runs in a sandboxed app container so install is reversible.
2. Run our [`QuickLookProtein-Setup.exe`](https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein-Setup.exe). SmartScreen will warn (our installer is unsigned) → **More info → Run anyway**.

### One-step Setup.exe

Run [`QuickLookProtein-Setup.exe`](https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein-Setup.exe) without installing QuickLook separately. Setup.exe ships a bundled copy of QL-Win's latest stable release (downloaded at release time from QL-Win's GitHub) and installs it if it isn't already on the machine. This works, but the GitHub installer of QL-Win is unsigned + doesn't auto-update — the Store path above is generally smoother.

### PowerShell one-liner

```powershell
irm https://raw.githubusercontent.com/ArioMoniri/QuickLookProtein/feature/ario-signed/Windows/install.ps1 | iex
```

Same scripts Setup.exe wraps. Useful when you want to read the install steps before running them (the script is auditable, single file, no admin required).

### Installer ZIP

[`QuickLookProtein-Windows-Installer.zip`](https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein-Windows-Installer.zip) — unpack, double-click `install.bat`. Same scripts as Setup.exe, no .exe shell around them.

### Bare plugin

[`QuickLookProtein.qlplugin`](https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein.qlplugin) — requires QuickLook already installed and running in the tray. Double-click the `.qlplugin` file; QL-Win registers it.

## Uninstall

### macOS
Drag `QuickLookProtein.app` from `/Applications` to the Trash. Per-user prefs live in `~/Library/Group Containers/<group>/Library/Preferences/com.ariomoniri.QuickLookProtein.plist` (Homebrew zaps these on `brew uninstall --cask --zap`).

### Windows
Settings → Apps → **QuickLookProtein** → Uninstall. Or delete `%AppData%\pooi.moe\QuickLook\QuickLook.Plugin\QuickLookProtein\` plus the `HKCU\Software\Classes\CLSID\{B7E4A6F1-…}` registry tree.
