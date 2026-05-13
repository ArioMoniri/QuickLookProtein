# 🧬 QuickLookProtein

> macOS Quick Look extension for previewing 3D molecular structure files (PDB, CIF, SDF, MOL, MOL2, XYZ, GRO, CUBE, PDBQT) — press <kbd>Space</kbd> in Finder, see your structure.

[![macOS](https://img.shields.io/badge/macOS-11.0%2B-blue?logo=apple)](https://www.apple.com/macos/)
[![Swift 5](https://img.shields.io/badge/Swift-5-orange?logo=swift)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Rendered by 3Dmol.js](https://img.shields.io/badge/rendered%20by-3Dmol.js-purple)](https://3dmol.csb.pitt.edu)

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

1. Download the latest release ZIP from the [Releases page](https://github.com/JethroHemmann/QuickLookProtein/releases).
2. Unzip and drag `QuickLookProtein.app` to `/Applications`.
3. Open the app once. If macOS warns the app can't be verified, follow [Apple's instructions for opening apps from unidentified developers](https://support.apple.com/en-us/102445).
4. The Quick Look + Thumbnail + Spotlight extensions are installed and activated automatically. You can verify them under **System Settings → General → Login Items & Extensions → Quick Look** (and similar for File Provider / Spotlight).

![Screenshot of System Preferences → Extensions → Quick Look](Screenshots/System_Preferences_Extensions.png "System Preferences → Extensions → Quick Look")

5. Select a `.pdb` / `.cif` / `.mol2` / etc. in Finder and press <kbd>Space</kbd>.

**Requires macOS 11+** for the main app, Quick Look preview, and Thumbnail extension. **macOS 12+** for the Spotlight indexing extension (`CSImportExtension` is macOS 12+).

---

## 🛠️ Building from source

```bash
git clone https://github.com/JethroHemmann/QuickLookProtein.git
cd QuickLookProtein
open Xcode/QuickLookProtein.xcodeproj
```

In Xcode → *Signing & Capabilities* for each of the four targets, pick your developer team and let Xcode regenerate signing identities.

The Quick Look preview and main-app targets exist in the project. **The Thumbnail and Spotlight Indexer targets need to be added in Xcode** (~60 seconds each) — see [docs/TARGET_SETUP.md](docs/TARGET_SETUP.md) for the exact click-paths.

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
- Multi-format support, smart rendering, Finder thumbnails, Spotlight indexing, drag-and-drop, and reliability hardening contributed by **[Ariorad Moniri](https://github.com/ArioMoniri)** (2026).

If you use QuickLookProtein in scientific work, please cite the underlying 3Dmol.js paper:

> Rego N & Koes D. *3Dmol.js: molecular visualization with WebGL.* Bioinformatics, 31(8):1322-4 (2015). DOI: [10.1093/bioinformatics/btu829](https://doi.org/10.1093/bioinformatics/btu829)

---

## 📜 License

MIT — see [LICENSE](LICENSE). Bundled 3Dmol.js is BSD-3-Clause; the LICENSE file lists the full third-party attributions (GLmol, Three.js, jQuery).

## 🐛 Reporting issues

Please open an [issue on GitHub](https://github.com/JethroHemmann/QuickLookProtein/issues).

## 🤝 Contributing

PRs welcome. Bug fixes, new file format support, and Phase 6 items from [docs/FUTURE_WORK.md](docs/FUTURE_WORK.md) are great places to start. See [CHANGELOG.md](CHANGELOG.md) for what's been added recently.
