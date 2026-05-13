# Changelog

All notable changes to QuickLookProtein are recorded here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com); this project does not strictly
adhere to SemVer because version numbers are driven by upstream releases.

## [1.7.1] — 2026-05-14

### 🎨 Changed

- **About panel redesign** — replaced the right-column wall of text with three
  card-style sections (Updates, Credits & Source, Quick Look troubleshooting),
  each with a colored icon plate. "Check for Updates" is now a prominent blue
  filled pill next to a quieter "Download from GitHub" fallback, instead of
  the small right-aligned control we had before. Build number is shown
  alongside the marketing version when they differ.
- **Custom button styles** — `PrimaryPillButtonStyle` and
  `SecondaryPillButtonStyle` so the new CTAs render consistently on macOS 11+
  (Apple's `.borderedProminent` requires macOS 12).

### 🪟 Windows

- **One-line installer** — `Windows/install.ps1` bootstraps QL-Win if it's
  missing, fetches the latest signed `.qlplugin` from GitHub, extracts to
  `%LocalAppData%\QuickLook\plugins\QuickLookProtein\`, and restarts the
  QuickLook tray. README features it as the recommended Windows path:
  `irm <raw-url> | iex`.
- **Branded splash overlay** in the WebView2 host — centered glyph +
  filename shown until WebView2 fires `NavigationCompleted`, replacing the
  ~150-400 ms black screen while the renderer warms.
- **Friendlier error card** — supported-formats hint + contact link instead
  of the single-line red banner.

## [Unreleased] — 2026

### 🆕 Added

#### New file formats
- **MOL2** (Tripos) preview with proper UTI registration
- **XYZ** (XMol) with automatic bond perception (without this 3Dmol's stick
  mode would render nothing for atom-only formats)
- **MOL** (MDL Molfile V2000) routed through the SDF parser
- **GRO** (GROMACS structure)
- **CUBE** / **CUB** (Gaussian Cube — atoms only for now; volumetric isosurfaces
  on the roadmap)
- **PDBQT** (AutoDock / Vina docking poses)

#### Smart rendering
- **Auto-styling** of protein + ligand structures: polymer in user's chosen
  style, ligands as sticks, metal ions as VDW spheres (otherwise invisible),
  waters hidden by default, buffer additives (SO4 / GOL / EDO / PEG / TRIS /
  etc.) as faint lines so they're visible but don't dominate.
- **Modified-residue detection** — MSE, SEP, TPO, PTR, CSO, HID/HIE/HIP, CYX,
  D-amino acids and other CCD-coded variants are merged into the polymer
  instead of treated as ligands.
- **Nucleic-acid detection** — DNA and RNA residues (DA/DT/DG/DC/DU/A/U/G/C/T/I
  plus 3-letter forms) get cartoon rendering when the user chooses cartoon
  style, instead of falling back to sticks.
- **Color schemes** — Spectrum (rainbow N→C), By chain, By element (CPK / Jmol),
  Secondary structure (ssJmol), By amino acid (Shapely).
- **Molecular surface** toggle (capped at 3,000 atoms to avoid OOM'ing the QL
  extension's small memory budget).
- **Hide hydrogens** toggle.
- **Show unit cell** for CIF / mmCIF / PDB with `CRYST1`.
- **Show info overlay** with filename · atom count · chain count · format.
- **Click any atom** to label it with element · atom name · residue · chain.

#### New Quick Look entry points
- **Thumbnail extension** — per-file Finder thumbnails in Cover Flow, Gallery
  view, large-icon view. Proteins render as molecular surfaces (cartoons are
  unrecognisable at icon sizes) and in a canonical isometric pose so two
  RCSB downloads of the same structure look visually similar.
- **Spotlight indexing extension** (`CSImportExtension`, macOS 12+) — indexes:
  - **PDB**: TITLE, COMPND, KEYWDS, AUTHOR, SOURCE organism, EXPDTA experimental
    method, REMARK 2 RESOLUTION, 4-letter PDB ID, HEADER deposition date
  - **mmCIF**: `_struct.title`, `_exptl.method`, `_reflns.d_resolution_high`,
    `_pdbx_database_status.recvd_initial_deposition_date`, `_entry.id`
  - **Small-mol CIF** (CCDC / COD): chemical formula, space group, CCDC refcode,
    DOI
  - **SDF**: first record name + first 5 names of multi-record SDFs
  - **MOL / MOL2 / XYZ**: name lines per spec
  - Handles CIF `loop_` blocks with proper walk-back detection for sibling
    keys.

#### Main-app improvements
- **Drag-and-drop** fifth tile in the settings app — drop a structure file
  to preview it live with the current settings without invoking Quick Look.
- Per-format atom-style picker for the new formats (in a collapsible "Additional
  formats" disclosure to keep the settings tidy).
- **Color scheme** picker and rendering-options toggles in the settings UI.

### 🔒 Security & reliability
- **Data injection moved** from a JS template literal to a
  `<script type="text/plain">` block, with `</script>` / NUL / BOM /
  curly-brace sanitisation. The previous character-stripping (`'`, `"`,
  `/*`, etc.) wouldn't have stopped a determined attacker; the new approach
  makes injection structurally impossible.
- **Multi-encoding file read** (UTF-8 → Latin-1) so CIF files containing
  non-ASCII author names don't fail with an opaque "couldn't read file"
  error.
- **25 MB file-size cap** with a friendly in-page "too large to preview"
  message — Quick Look extensions are memory-capped and parsing a 200 MB PDB
  would jetsam the host.
- **`handler(nil)` moved** to `WKNavigationDelegate.didFinish` so Quick Look
  has an accurate ready-state. Re-invocations during Finder scrub fire the
  prior handler before overwriting it.
- **Friendly in-page error UI** when the template, file, or parser fails —
  replaces the previous "Error while loading HTML or PDB" raw text.
- **WebView leak fix** in the settings app — `NSViewRepresentable` no longer
  allocates a fresh `WKWebView` per SwiftUI body re-render.
- **Settings actually load** in the Quick Look extension — `@StateObject` on
  an `NSViewController` silently did nothing; replaced with plain ownership.

### 🐛 Fixed
- `viewer.addSurface` could OOM the QL extension on large proteins — now
  capped at 3,000 atoms.
- `addUnitCell` was extending the camera bounds *after* `zoomTo()`, shrinking
  the molecule view inside a much larger box — now zoom runs first.
- Invalid `{ invert: true }` AtomSpec in the smart-styling selector was being
  silently ignored by 3Dmol (treated as match-nothing or match-everything
  depending on version) — replaced with serial-array selectors that are
  universally supported.
- Default rendering for proteins-with-ligands now matches the standard 3Dmol
  idiom; previously every atom got the same style.

### 📚 Docs
- New [docs/TARGET_SETUP.md](docs/TARGET_SETUP.md) with the exact Xcode
  click-paths for adding the QLThumbnail and MDImporter targets, including
  the `MACOSX_DEPLOYMENT_TARGET = 12.0` override required for the Spotlight
  indexer.
- [docs/FUTURE_WORK.md](docs/FUTURE_WORK.md) tracks deferred items
  (CUBE isosurface, Sparkle integration, Phase 6 polish).
- README rewritten with the full feature list, supported formats, install /
  build / verify steps.

## [1.5] — 2022

- Settings refactored into their own class (`SettingsStorage`).
- Colors are stored as their individual components.
- Added more UTIs for CIF and SDF.

## [1.4] — 2022

- Initial release with PDB / SDF / CIF support.
