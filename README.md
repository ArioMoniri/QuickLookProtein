# 🧬 QuickLookProtein

> macOS Quick Look extension for previewing 3D molecular structure files (PDB, CIF, SDF, MOL, MOL2, XYZ, GRO, CUBE, PDBQT) — press <kbd>Space</kbd> in Finder, see your structure.

[![macOS](https://img.shields.io/badge/macOS-11.0%2B-blue?logo=apple)](https://www.apple.com/macos/)
[![Swift 5](https://img.shields.io/badge/Swift-5-orange?logo=swift)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Rendered by 3Dmol.js](https://img.shields.io/badge/rendered%20by-3Dmol.js-purple)](https://3dmol.csb.pitt.edu)
[![Latest release](https://img.shields.io/github/v/release/ArioMoniri/QuickLookProtein?display_name=tag)](https://github.com/ArioMoniri/QuickLookProtein/releases)

### 📥 Download

<p align="center">
  <a href="https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein.dmg"><img src="docs/download-macos.svg" alt="Download QuickLookProtein for macOS" height="72"></a>
  &nbsp;
  <a href="https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein-Setup.exe"><img src="docs/download-windows.svg" alt="Download QuickLookProtein Setup for Windows" height="72"></a>
</p>

<p align="center"><sub>macOS → signed <code>.dmg</code>, drag to Applications · Windows → single <code>Setup.exe</code>, double-click. <strong>One click each.</strong></sub></p>

<p align="center">macOS · Developer-ID signed &amp; notarised &nbsp;|&nbsp; Windows · <strong>under development, not stable yet</strong> (QL-Win plugin, unsigned)</p>

**macOS:** open the disk image, drag **QuickLookProtein.app** into **Applications**, then hit <kbd>Space</kbd> on any `.pdb` / `.cif` / `.mol2` / etc. file in Finder.

<details>
<summary>🎨 UI versions — Settings-app facelift in v1.7.47</summary>

The host **Settings app** went through a redesign in **v1.7.47**:

| Version range | Settings layout |
|---|---|
| **v1.7.47 and later** | macOS-System-Settings-style **sidebar** (General · File Formats · Appearance · Rendering · Toolbar · Info Overlay · Multi-file · Software Update · About) with live 3Dmol previews per format and a liquid-glass backdrop |
| **v1.7.46 and earlier** | Flat single-page layout — settings on top, preview tiles below |

The Quick Look extension itself (what spacebar in Finder shows) is **the same** in both — only the Settings window changed. If you specifically prefer the older flat layout, [v1.7.46](https://github.com/ArioMoniri/QuickLookProtein/releases/tag/v1.7.46) is the last build with it; note you'll miss every fix and feature since (CIF unit cell CRYST1, Sparkle no-modal, format-disable gating, Multi-file Quick Action merge, magenta accent, real cdjson/mmtf samples, etc.).

</details>

<details>
<summary>🔄 Software Update — if "auto-updates unavailable" persists</summary>

The Software Update panel will say **"Auto-updates are unavailable"** with a reason if Sparkle couldn't start. Common causes:

1. **Installed version is older than v1.7.45.** Earlier builds called Sparkle with `startingUpdater: true`, which presented a modal and broke the auto-update loop. The fix is in v1.7.45+, but it can't update *itself* — you need one manual DMG download from [Releases](https://github.com/ArioMoniri/QuickLookProtein/releases/latest) to break the cycle.
2. **Unsigned dev build.** If you compiled locally, the SUPublicEDKey is the placeholder — auto-updates are off by design. Use "Download from GitHub" for the signed release.
3. **App Group container not provisioned.** Console shows `Using kCFPreferencesAnyUser with a container is only allowed for System Containers` — same dev-build symptom; signed releases ship with the entitlement intact.

In all three cases the panel falls back to a prominent **"Download from GitHub"** button instead of trying to update through a broken Sparkle. After installing the new DMG manually once, auto-updates resume normally.

</details>

### 🪟 Windows

**Install.** Download [`QuickLookProtein-Setup.exe`](https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein-Setup.exe), double-click it, click **More info → Run anyway** on SmartScreen, click **Install**. Done.

The installer bundles QuickLook (QL-Win) and installs it for you if you don't already have it. The Settings app opens automatically on first install; you can re-open it any time via **Start Menu → QuickLookProtein Settings**, or uninstall via **Settings → Apps → QuickLookProtein**.

**Use.** Press <kbd>Space</kbd> on any of these in Explorer:
`.pdb` `.ent` `.cif` `.mmcif` `.sdf` `.mol` `.mol2` `.xyz` `.gro` `.cube` `.pqr` `.vasp` `.cdjson` `.mmtf`

Switch a folder to **Icon / Tile / Gallery view** to see CPK / cartoon-ribbon thumbnails of every supported file.

<details>
<summary>Other install paths (PowerShell, manual, troubleshooting)</summary>

```powershell
# One-liner — same effect as Setup.exe, no UI:
irm https://raw.githubusercontent.com/ArioMoniri/QuickLookProtein/feature/ario-signed/Windows/install.ps1 | iex
```

[`QuickLookProtein-Windows-Installer.zip`](https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein-Windows-Installer.zip) — unpack, double-click `install.bat`. Same scripts as Setup.exe; bring this one if you want to read the install steps before running.

[`QuickLookProtein.qlplugin`](https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein.qlplugin) — bare plugin file. Requires [QuickLook](https://github.com/QL-Win/QuickLook/releases/latest) installed *first*; with QuickLook running in the tray, double-click the `.qlplugin` to register it.

**If Space-bar still shows raw text after install**, open **Start Menu → QuickLookProtein Settings → Diagnostics → Open plugin log**. The plugin writes a trace on every preview attempt; an empty file means QL-Win never even loaded our DLL (check **Open QuickLook log** in the same card for the host-side reason). Restarting the QuickLook tray from the same card is also one click.

The Windows installer is **unsigned** — SmartScreen warns on first launch. The plugin runs inside QuickLook, not as a standalone exe.

</details>

> 🔱 This is **[Ariorad Moniri](https://github.com/ArioMoniri)'s signed fork** of the original [QuickLookProtein by Jethro Hemmann](https://github.com/JethroHemmann/QuickLookProtein), distributed via [releases on this fork](https://github.com/ArioMoniri/QuickLookProtein/releases) and notarised under Apple Developer team `FF68N39FU5`. Looking for the upstream pull request? See [the PR branch](https://github.com/ArioMoniri/QuickLookProtein/tree/feature/3dmol-upgrade).

QuickLookProtein integrates with macOS Quick Look so you can preview protein and small-molecule structures the same way you preview PDFs and images — just select a file in Finder and tap <kbd>Space</kbd>. Rendering is performed by [3Dmol.js](https://3dmol.csb.pitt.edu) inside a `WKWebView`, so previews are interactive (drag to rotate, scroll to zoom, click an atom to label it).

![Demonstration of the Quick Look extension in Finder](Screenshots/QuickLook.gif "Demonstration of the Quick Look extension in Finder")

---

## ✨ Features

### 📁 Supported file formats
| Format | Extensions | Notes |
|--------|------------|-------|
| Protein Data Bank | `.pdb` `.ent` | The classic format from rcsb.org |
| Crystallographic Information File | `.cif` `.mmcif` | Both small-molecule (CCDC / COD) and macromolecular |
| MDL Structure-Data File | `.sdf` | Multi-record SDFs render the first molecule |
| MDL Molfile | `.mol` | V2000 format |
| Tripos MOL2 | `.mol2` | With Tripos atom typing |
| XMol XYZ | `.xyz` | Bonds auto-perceived |
| GROMACS structure | `.gro` | First frame only for trajectories |
| Gaussian Cube | `.cube` `.cub` | Atoms only (volumetric isosurface in a future release) |
| AutoDock / Vina | `.pdbqt` | Docking poses |

### 🎨 Smart rendering
- **Protein + ligand auto-styling**: when a structure contains both a polymer and a ligand, the polymer renders with your chosen style (cartoon by default) and ligands as sticks — the standard 3Dmol idiom for biology.
- **Metal-ion spheres**: Zn, Fe, Mg, Mn, Cu and other single-atom hetero residues are rendered as VDW spheres (otherwise they'd be invisible — they have no bonds).
- **Nucleic-acid cartoons**: DNA and RNA (DA/DT/DG/DC/DU/A/U/G/C/T/I) are detected and shown as cartoons too, not just sticks.
- **Modified-residue handling**: MSE, SEP, TPO, PTR, CSO, HID/HIE, CYX, D-amino acids and other CCD-coded variants are merged into the polymer instead of treated as ligands.
- **Color schemes**: Spectrum (N→C rainbow), By chain, By element (CPK), Secondary structure, By amino acid.
- **Molecular surface** rendering with a 3,000-atom cap so Quick Look's tight memory budget isn't blown.
- **Hide hydrogens**, **Show unit cell** (CIF), **Show info overlay** (filename · atom count · chain count · format), **Background color** with opacity, **Auto-rotate** speed control.
- **Click any atom** to label it with element · atom name · residue · chain.

### 🖼️ Finder thumbnails
Each file gets a per-content thumbnail in Cover Flow, Gallery view, and large-icon view — proteins render as molecular surfaces in a canonical isometric pose so two RCSB downloads of the same structure look similar.

### 🔎 Spotlight indexing
Search by **PDB title**, **PDB accession** (`1CRN`, `6OC6`), **author**, **organism**, **experimental method**, **resolution**, **CCDC refcode**, or **space group**. The Spotlight extension parses PDB, mmCIF, small-molecule CIF, SDF, MOL, MOL2, and XYZ headers.

```bash
mdfind 'kMDItemKind == "Protein Data Bank file" && kMDItemKeywords == "X-RAY*"'
```

### ⚙️ Settings app
The bundled settings app lets you set the default atom style per format, color scheme, rotation speed, background color, and rendering toggles. It also has a fifth tile that accepts drag-and-drop — preview any structure with the current settings without invoking Quick Look.

![Screenshot of the main app](Screenshots/Main_app.png "Main app used to set settings")

---

## 📦 Installation

1. Download `QuickLookProtein-{version}.zip` from the [Releases page on this fork](https://github.com/ArioMoniri/QuickLookProtein/releases).
2. Unzip and drag `QuickLookProtein.app` to `/Applications`.
3. Open the app once. The build is signed and notarised by Apple, so it should launch without a warning. If you ever see a "could not be verified" dialog (e.g. on a fresh Mac before notarisation propagates), follow [Apple's instructions for opening apps from unidentified developers](https://support.apple.com/en-us/102445).
4. The Quick Look preview, Thumbnail, and Spotlight extensions are installed and activated automatically. Verify under **System Settings → General → Login Items & Extensions → Quick Look** (and similar for File Provider / Spotlight).

![Screenshot of System Preferences → Extensions → Quick Look](Screenshots/System_Preferences_Extensions.png "System Preferences → Extensions → Quick Look")

5. Select a `.pdb` / `.cif` / `.mol2` / etc. in Finder and press <kbd>Space</kbd>.

**Requires macOS 11+** for the main app, Quick Look preview, and Thumbnail extension. **macOS 12+** for the Spotlight indexing extension (`CSImportExtension` is macOS 12+).

### 🔄 Auto-update

The app uses **[Sparkle](https://sparkle-project.org)** for in-place updates. When a new version is published you'll see a dialog with **Install Update** / **Remind Me Later** / **Skip This Version**. Clicking *Install Update* downloads the signed `.zip`, verifies the EdDSA signature, replaces the app in `/Applications`, and relaunches — no manual re-download or drag-to-Applications step required.

Checks run automatically every 24 hours; trigger one on-demand from **QuickLookProtein menu → Check for Updates…** or from the About section in the settings window.

Releases are signed by Apple (Developer ID `FF68N39FU5`, notarised) **and** by Sparkle's EdDSA key, so a man-in-the-middle on the update channel can't trick Sparkle into installing something I didn't sign.

---

## 🛠️ Building from source

```bash
git clone https://github.com/ArioMoniri/QuickLookProtein.git
cd QuickLookProtein
git checkout feature/ario-signed   # signed-release branch
open Xcode/QuickLookProtein.xcodeproj
```

In Xcode → *Signing & Capabilities* for each of the four targets, pick your developer team and let Xcode regenerate signing identities.

The Quick Look preview and main-app targets exist in the project. **The Thumbnail and Spotlight Indexer targets need to be added in Xcode** (~60 seconds each) — see [docs/TARGET_SETUP.md](docs/TARGET_SETUP.md) for the exact click-paths.

### Releasing a new version

The release pipeline is **fully automated** via GitHub Actions:

```bash
git tag v2.1.0
git push origin v2.1.0
```

GitHub Actions then builds, signs with Developer ID, notarises with Apple, Sparkle-signs the zip, publishes a GitHub Release, and updates `docs/appcast.xml` so installed clients see the update automatically. See [docs/RELEASE.md](docs/RELEASE.md) and [docs/SPARKLE_SETUP.md](docs/SPARKLE_SETUP.md) for the one-time setup (certificate export, Sparkle key generation, GitHub Actions secrets).

After building, flush Quick Look's cache to pick up the new extension:

```bash
qlmanage -r && qlmanage -r cache
```

---

## 🧪 Verifying it works

```bash
# Quick Look preview
qlmanage -p path/to/structure.pdb

# Thumbnail
qlmanage -t -s 256 path/to/structure.pdb

# Spotlight indexer
mdimport -L                              # confirms importer is registered
mdimport ~/some.pdb                      # forces re-index of one file
mdls ~/some.pdb                          # prints indexed metadata
```

If a particular file extension isn't recognised, please include this output when reporting the issue:

```bash
mdls -name kMDItemContentType /path/to/your/file.ext
```

---

## 📂 Project layout

```
Xcode/
├── QuickLookProtein/    SwiftUI settings app (main app target)
├── QLExtension/         Quick Look preview extension (Space-bar preview)
├── QLThumbnail/         Quick Look thumbnail extension (Finder icons)
├── MDImporter/          Spotlight indexing extension (search by metadata)
└── Shared/              Settings, helpers, 3Dmol_viewer.html template, 3Dmol.js
docs/
├── TARGET_SETUP.md      How to add QLThumbnail + MDImporter targets in Xcode
└── FUTURE_WORK.md       Punted features and notes for future work
```

---

## 🙏 Credits

- Original Quick Look extension authored by **[Jethro Hemmann](https://github.com/JethroHemmann)** (2021–2022).
- 3D rendering by **[3Dmol.js](https://3dmol.csb.pitt.edu)** — Rego & Koes, *Bioinformatics* 2015.
- Multi-format support, smart rendering, Finder thumbnails, Spotlight indexing, drag-and-drop, auto-updater, and reliability hardening by **[Ariorad Moniri](https://github.com/ArioMoniri)** (2026).

### About the maintainer of this fork

> I'm a dedicated medical student and research fellow passionate about bridging medicine and technology. With experience in both wet and dry lab environments and expertise in bioinformatics, I enjoy developing web and macOS applications that solve real-world problems.

If you use QuickLookProtein in scientific work, please cite the underlying 3Dmol.js paper:

> Rego N & Koes D. *3Dmol.js: molecular visualization with WebGL.* Bioinformatics, 31(8):1322-4 (2015). DOI: [10.1093/bioinformatics/btu829](https://doi.org/10.1093/bioinformatics/btu829)

---

## 📜 License

MIT — see [LICENSE](LICENSE). Bundled 3Dmol.js is BSD-3-Clause; the LICENSE file lists the full third-party attributions (GLmol, Three.js, jQuery).

## 🐛 Reporting issues

Please open an [issue on this fork](https://github.com/ArioMoniri/QuickLookProtein/issues). For upstream issues unrelated to the fork-specific changes (auto-updater, notarisation), feel free to use [Jethro's tracker](https://github.com/JethroHemmann/QuickLookProtein/issues) as well.

## 🤝 Contributing

PRs welcome. Bug fixes, new file format support, and Phase 6 items from [docs/FUTURE_WORK.md](docs/FUTURE_WORK.md) are great places to start. See [CHANGELOG.md](CHANGELOG.md) for what's been added recently.
