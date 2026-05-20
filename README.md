# 🧬 QuickLookProtein2

Press <kbd>Space</kbd> on a protein/molecule file in Finder (or Windows Explorer) and see the 3D structure.

[![macOS](https://img.shields.io/badge/macOS-11.0%2B-blue?logo=apple)](https://www.apple.com/macos/)
[![Windows](https://img.shields.io/badge/Windows-10%2B-0078D4?logo=windows)](https://www.microsoft.com/windows)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/ArioMoniri/QuickLookProtein?display_name=tag&sort=semver&cacheSeconds=300&label=release)](https://github.com/ArioMoniri/QuickLookProtein/releases/latest)
[![Homebrew Cask](https://img.shields.io/badge/Homebrew-quicklookprotein-yellow?logo=homebrew)](Casks/quicklookprotein.rb)

A multi-format Quick Look extension for macOS and a QL-Win plugin for Windows. Rendering by [3Dmol.js](https://3dmol.csb.pitt.edu); fork of [Jethro Hemmann's QuickLookProtein](https://github.com/JethroHemmann/QuickLookProtein) with multi-format support, smart styling, thumbnails, and Windows support added.

<p align="center">
  <a href="https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein.dmg"><img src="docs/download-macos.svg" alt="Download for macOS" height="64"></a>
  &nbsp;
  <a href="https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein-Setup.exe"><img src="docs/download-windows.svg" alt="Download for Windows" height="64"></a>
  &nbsp;
  <a href="#install"><img src="docs/download-homebrew.svg" alt="Install via Homebrew" height="64"></a>
</p>

## Install

### 🍎 macOS

Open the DMG → drag **QuickLookProtein** to **Applications**. That's it — press <kbd>Space</kbd> on any `.pdb` / `.cif` / `.sdf` / `.mol` / `.mol2` / `.xyz` / `.gro` / `.cube` / `.pqr` / `.vasp` / `.cdjson` / `.mmtf` file in Finder.

**Homebrew** (alternative):
```bash
brew tap ariomoniri/quicklookprotein https://github.com/ArioMoniri/QuickLookProtein
brew install --cask quicklookprotein
```

The macOS build is Developer-ID signed and notarised by Apple — no Gatekeeper warning.

### 🪟 Windows

QuickLookProtein2 is a plugin for **[QuickLook](https://github.com/QL-Win/QuickLook)**, a free Space-bar previewer for Windows (the QL-Win project, no relation to Apple's Quick Look). You need QuickLook installed for our plugin to work.

**Recommended path** — install QuickLook from the [Microsoft Store](https://apps.microsoft.com/detail/9NV4BS3L1H4S) first, then run our `QuickLookProtein-Setup.exe`. The Store version is signed by Microsoft and auto-updates.

**One-step path** — run our [`QuickLookProtein-Setup.exe`](https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein-Setup.exe) directly; it installs the GitHub release of QuickLook if you don't already have it. The installer is unsigned — SmartScreen will warn (**More info → Run anyway**).

After install, press <kbd>Space</kbd> on any supported file in Explorer; switch a folder to **Icon / Tile / Gallery view** to see thumbnails. (Details/List views render the file-type icon, not the thumbnail — see [Troubleshooting](docs/TROUBLESHOOTING.md).)

> **Status:** Windows support is under active development. macOS is the stable, signed/notarised platform.

➡️ Full install options (PowerShell one-liner, manual `.qlplugin`, dev builds): [`docs/INSTALL.md`](docs/INSTALL.md).

## Features

| | macOS | Windows |
|---|:---:|:---:|
| Interactive 3D preview (Space) | ✅ | ✅ |
| Cartoon · stick · sphere · line · surface | ✅ | ✅ |
| Smart protein + ligand styling | ✅ | ✅ |
| Finder/Explorer thumbnails (Icon view) | ✅ | ✅ |
| Per-format style settings | ✅ | ✅ |
| Background, rotation, zoom, color scheme | ✅ | ✅ |
| Auto-update | Sparkle | in-app + appcast |
| Spotlight indexing | ✅ | — |
| Quick Actions / Services (Quick Look strip) | ✅ | — |

**Supported formats** — PDB · ENT · PDBQT · PQR · CIF · mmCIF · SDF · MOL · MOL2 · XYZ · GRO · CUBE · CDJSON · MMTF · VASP/POSCAR. Comp-chem outputs (Gaussian `.gjf`, ORCA `.orcaout`, Q-Chem) and cryo-EM density (`.ccp4` / `.mrc` / `.map`) get pre-parsed on macOS.

**Color schemes** — Spectrum · Chain · Element · Secondary structure · Amino acid · B-factor / pLDDT.

## Settings

Open the **QuickLookProtein2** app (macOS) or **QuickLookProtein Settings** from the Start Menu (Windows). Both have a sidebar with General · File Formats · Appearance · Rendering · Toolbar · Info Overlay · Thumbnails · Software Update · About — settings save instantly and apply to the next preview, no restart needed.

## Auto-update

- **macOS**: Sparkle. Built-in `Check for Updates…` menu item + automatic background checks. Signed releases install transparently.
- **Windows**: in-app updater in `Settings → Software Update` queries `/releases/latest` on GitHub, downloads `QuickLookProtein-Setup.exe`, runs it. Auto-check is opt-in.

## Troubleshooting

The most common issues + how to surface the actual error:

- **macOS "An error occurred while launching the installer"** — Settings → Software Update → **Open update log** (shows the underlying `NSError` domain/code/reason).
- **Windows thumbnails are blank/white in Icon view** — Settings → About → Diagnostics → **Test thumbnail provider**, then **Repair now** if registration is missing.
- **Windows previews show raw text** — Settings → About → Diagnostics → **Open plugin log**.

➡️ Full troubleshooting playbook + log locations: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## Building from source

```bash
# macOS
open Xcode/QuickLookProtein.xcodeproj    # Cmd-R to run, ⌘B to build

# Windows
dotnet build Windows/QuickLookProtein.Plugin/QuickLookProtein.Plugin.csproj -c Release
dotnet build Windows/QuickLookProtein.Settings/QuickLookProtein.Settings.csproj -c Release
```

Releases are tagged `vX.Y.Z` — pushing a tag fires `.github/workflows/release.yml` which builds, signs, notarises, and publishes both platforms. Cask SHA256 is bumped automatically via `.github/workflows/cask-bump.yml`.

## Credits

Originally built by **[Jethro Hemmann](https://github.com/JethroHemmann/QuickLookProtein)** (2021–2022). This fork by [Ariorad Moniri](https://github.com/ArioMoniri) (2026) adds multi-format support, smart protein+ligand styling, surfaces, Finder thumbnails, Spotlight, drag-and-drop preview, Quick Actions, AR Quick Look USDZ export, DCD/TRR/XTC trajectories, Sparkle auto-update, and the Windows port. Rendering by [3Dmol.js](https://3dmol.csb.pitt.edu) (Rego & Koes, 2015).

## License

MIT — see [`LICENSE`](LICENSE). 3Dmol.js: BSD-3-Clause. QuickLook for Windows: GPL-3.

## Reporting issues

Use [GitHub Issues](https://github.com/ArioMoniri/QuickLookProtein/issues). Attach the relevant log (paths in [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)) so we can see the actual failure rather than guess.

🤖 *Project history, version-stamped features, and the long-form changelog live in [CHANGELOG.md](CHANGELOG.md).*
