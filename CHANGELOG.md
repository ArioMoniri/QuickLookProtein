# Changelog

All notable changes to QuickLookProtein are recorded here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com); this project does not strictly
adhere to SemVer because version numbers are driven by upstream releases.

## [1.7.13] — 2026-05-14

### 🐛 Fixed

- **The Space-bar preview actually works now.** Even after v1.7.11
  retargeted the plugin to net472, QL-Win was still falling back to
  its text viewer (the user saw raw ATOM records instead of a 3D
  structure). Two root causes, both now fixed:
  - **`WebView2Loader.dll` (native bridge)** wasn't being copied into
    the `.qlplugin`. On .NET Core / .NET 5+, the SDK auto-deploys
    runtime-specific natives from the NuGet package's
    `runtimes/win-x64/native/` folder; on .NET Framework that
    auto-deploy doesn't happen. QL-Win loaded the managed DLL fine
    but the first WebView2 call hit `DllNotFoundException` and the
    plugin got silently dropped. Added a `CopyWebView2LoaderNative`
    MSBuild target that copies the x64 native loader into the output
    folder; the package step picks it up automatically. The
    `PlatformTarget=x64` line on the csproj makes sure we match
    QL-Win's process bitness.
  - **`Priority`** raised from 5 to 100. QL-Win's built-in TextViewer
    plugin claims any "text-readable" file (which a .pdb obviously is)
    with low single-digit priority. Priority 5 wasn't a comfortable
    win over the text fallback in practice; 100 settles the order
    unambiguously.

### 🆕 Added

- **Windows Explorer thumbnails!** New `QuickLookProtein.Thumbnail.dll`
  shell extension renders depth-sorted CPK previews of `.pdb`, `.ent`,
  `.pdbqt`, `.pqr`, `.cif`, `.mmcif`, `.sdf`, `.mol`, `.mol2`, `.xyz`,
  `.gro`, `.cube`, `.cub`, `.vasp`, `.poscar`, `.cdjson`, and `.mmtf`
  directly in Explorer's Icon / Tile / Gallery views. Mirrors the
  macOS `QLThumbnail.appex` look (dark background, isometric pose,
  Jmol CPK palette). Pure-managed renderer using System.Drawing - no
  WebView2 cold-start cost, fast enough for Explorer's thumbnail
  cache.
  - Implements `IThumbnailProvider` + `IInitializeWithStream` via
    hand-rolled COM interop (no SharpShell dependency).
  - Per-user registration (HKCU) so the installer needs no admin
    rights.
  - Best-effort `ie4uinit.exe -ClearIconCache` after registration so
    existing files start showing thumbnails without a reboot.
  - Atom-count capped at 5,000 so a 100k-atom PDB doesn't stall the
    thumbnail cache.
  - Stable CLSID `B7E4A6F1-2D6E-4F58-9B1B-2E5A1F0B97A1`.

## [1.7.12] — 2026-05-14

### 🪟 Windows — installer feels less alarming

- **Setup.exe now bundles the QuickLook (QL-Win) installer.** Users
  no longer see a second "Downloading 60 MB..." pause and a *second*
  SmartScreen warning when the sub-installer runs. The release
  workflow fetches the latest QL-Win release at build time, drops
  the `.exe` into the Inno Setup payload, and `install.ps1`
  auto-detects the sibling `QuickLook-*.exe` and installs from it
  with no network. Setup.exe grows ~60 MB → ~62 MB but the install
  is now offline-capable and visibly single-step.
- **Cmd console hidden during Setup.exe install.** Inno Setup runs
  install.bat with `runhidden` and pipes stdout/stderr to
  `%TEMP%\QuickLookProtein-install.log` for post-hoc diagnostics.
  The user sees only the Inno Setup wizard with a clear StatusMsg
  ("Installing QuickLook host and the molecule plugin…") and its
  built-in progress bar.
- **install.bat skips its banner / pauses** when invoked via
  Setup.exe (detected via `QLP_SETUP_EXE=1`). Standalone manual runs
  still get the friendly intro and final keypress.
- **install.ps1's spinner skipped** under Setup.exe too (no visible
  console to render to anyway).

### 📚 Docs

- **`docs/FUTURE_WORK.md`** gained a Windows-thumbnails section
  describing the work needed to add Explorer thumbnails (separate
  `IThumbnailProvider` COM DLL, per-extension shell-handler
  registration, icon-cache invalidation). Not in 1.7.x scope.

## [1.7.11] — 2026-05-14

### 🐛 Fixed

- **The Windows plugin never actually loaded.** v1.7.0 → v1.7.10 all
  shipped a `.qlplugin` targeting `net8.0-windows`. QL-Win is a
  .NET Framework 4.7.2 application — its CLR cannot load .NET Core /
  .NET 5+ assemblies, so QL-Win logged a silent `TypeLoadException`
  at startup and dropped our plugin. From the user's side: installer
  ran, plugin file landed in `%LocalAppData%\QuickLook\plugins\…`,
  QuickLook ran, and pressing Space on a `.pdb` did **nothing**.
  Retargeted `QuickLookProtein.Plugin.csproj` to `net472` (with
  `LangVersion=10.0` to keep file-scoped namespaces and nullable
  reference types working). Replaced `File.ReadAllTextAsync` (a
  .NET Core only API) with `Task.Run(() => File.ReadAllText(...))`
  to keep the call sites async.

  This is the root cause of the entire "Space does nothing" Windows
  experience. Everything else — the installer, the file association,
  the plugin folder layout — was fine. The DLL itself just wasn't
  compatible with the CLR loading it.

## [1.7.10] — 2026-05-14

### 🐛 Fixed

- **Installer aborted with "Access is denied" when QuickLook was
  already running elevated.** If the user had previously launched
  QL-Win via an elevated path (UAC-prompted Setup.exe, or running it
  As Administrator from a previous session) and then ran our
  installer unelevated, `Stop-Process -Force` against the higher-
  integrity QuickLook process surfaced `CouldNotStopProcess: Access
  is denied` and bubbled out as install exit code 1 — even though
  the plugin was already on disk.

  `Restart-QuickLookHost` now walks three strategies in order:
  graceful `CloseMainWindow()` (no elevation needed), then
  `Stop-Process -Force`, then `taskkill /F /IM`. If all three fail
  the script prints clear recovery instructions ("right-click the
  QuickLook tray icon → Exit, then re-launch from Start Menu") and
  returns success — the plugin is in place, QL-Win will pick it up
  on its next start.

  Top-level invocation also wraps the restart step in try/catch so
  an unexpected exception there can't fail the install either.

## [1.7.9] — 2026-05-14

### 🐛 Fixed

- **First-time Windows install left QuickLook installed but not running**,
  so the plugin was sitting in `%LocalAppData%\QuickLook\plugins\` with
  no daemon to load it. Double-clicking the `.qlplugin` separately
  also did nothing because Windows' file association only fires for
  a running QuickLook. `install.ps1`'s `Restart-QuickLookHost` only
  restarted QuickLook if it was *already* running — fine for upgrades,
  silently broken for first-time setup. It now actively starts
  QuickLook in both cases, locates the binary by probing
  `%LocalAppData%\Programs\QuickLook\`, `Program Files\QuickLook\`,
  and `Program Files (x86)\QuickLook\`, and waits 2 s to confirm the
  process is alive before reporting success.
- **Post-install verification**: install.ps1 now checks that
  `QuickLook.Plugin.Protein.dll` is actually present in the install
  folder after the extraction and prints the folder contents if it
  isn't, so a silently-failed Expand-Archive surfaces in the cmd log
  instead of being discovered the next day when previews still don't
  work.

## [1.7.8] — 2026-05-14

### 🪟 Windows

- **Setup.exe no longer appears to hang** during the QL-Win install
  step. Three changes:
  - `install.ps1` calls QL-Win's installer with
    `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS`
    instead of `/SILENT`. /SILENT pops a progress dialog that
    sometimes lands behind our cmd window, so users saw nothing
    happening and assumed the install had frozen.
  - While waiting on the silent install, `install.ps1` runs a
    polling spinner (`Working | (15 s)`) so the user can tell the
    process is alive.
  - `install.bat` detects the Setup.exe context via a `QLP_SETUP_EXE=1`
    env var Inno Setup sets in `[Run]` and auto-closes 5 seconds
    after success instead of waiting for a keypress — which kept
    the parent Inno Setup wizard stuck on "Finishing installation…"
    until the user noticed and dismissed the hidden cmd window.
- **Inno Setup `[Run]` step** invokes install.bat via
  `cmd.exe /C set QLP_SETUP_EXE=1 && install.bat` so the auto-close
  path triggers, and shows a `StatusMsg` ("Installing QuickLook host
  and plugin (this can take up to a minute)…") on the wizard while
  it runs.

## [1.7.7] — 2026-05-14

### 🐛 Fixed

- **install.ps1 parser error on Windows PowerShell 5.1** — the script
  contained em-dashes (`—`) and arrows (`→`) in comments and prompt
  strings. Windows PowerShell 5.1 (the default `powershell.exe` shell,
  which install.bat invokes) reads files without a BOM as the system
  ANSI codepage, not UTF-8 — those multi-byte UTF-8 sequences got
  mis-decoded into garbled quote characters, which the parser then
  flagged with cascading "string is missing the terminator" errors
  pointing at innocent ASCII lines further down. install.ps1 is now
  pure ASCII.

### 🪟 Windows

- **Dropped the `QuickLookProtein-Windows-Installer-latest.zip` alias.**
  Setup.exe is the recommended path; the installer zip remains as a
  versioned fallback for users who want to read the scripts before
  running them. Releases now ship six Windows assets instead of seven
  (one .qlplugin, one versioned + one alias, the installer bundle, and
  Setup.exe — no duplicate "-latest" zip).

## [1.7.6] — 2026-05-14

### 🪟 Windows

- **Setup.exe build finally green.** Two CI iterations missed: ISCC
  was resolving relative `OutputDir=build` against its post-Push-
  Location cwd (so it dropped the .exe in `build/build/`), and a
  PowerShell here-string was injecting leading whitespace into
  `[Files]` lines that some ISCC versions choke on. Fixed by building
  the .iss line-by-line with absolute paths and removing the
  Push-Location dance.

## [1.7.5] — 2026-05-14

### 🪟 Windows

- **Setup.exe is finally building.** v1.7.4 tried to produce it via
  7-Zip's SFX module but `windows-latest` doesn't bundle the SFX
  payload (`7zSD.sfx` / `7zS.sfx` live in the separately-downloadable
  7-Zip Extras pack). Switched to Inno Setup, which is preinstalled
  on every github-hosted Windows runner — same one-click outcome,
  no external fetch needed.

## [1.7.4] — 2026-05-14

### 🪟 Windows

- **`QuickLookProtein-Setup.exe`** — true one-click installer for
  Windows. A 7-Zip self-extracting `.exe` that bundles the
  `.qlplugin`, `install.ps1`, and `install.bat`, prompts the user
  for confirmation, and auto-runs `install.bat` after extraction.
  Replaces the previous "download zip → unzip → double-click .bat"
  three-step flow with a single double-click.
- README's **Download for Windows** button now points at
  `releases/latest/download/QuickLookProtein-Setup.exe` instead of
  the installer zip. The zip and the plain `.qlplugin` are still
  uploaded as fallbacks (advanced / fully-manual installs).

## [1.7.3] — 2026-05-14

### 🪟 Windows

- **All-in-one installer zip** — releases now ship a
  `QuickLookProtein-Windows-Installer.zip` bundle containing
  `install.bat`, `install.ps1`, the `.qlplugin`, and a plaintext
  README. Users can download, unzip, and double-click `install.bat` —
  no PowerShell command typing, no hunting for the right asset on the
  release page.
- **`install.bat` double-click wrapper** — friendly intro, runs
  `install.ps1` with `-ExecutionPolicy Bypass`, prints status, waits
  for a keypress on exit so the user can read the result.
- **`install.ps1 -LocalPlugin` parameter + auto-detection** —
  when a sibling `QuickLookProtein*.qlplugin` is present next to the
  script (offline bundle case) the installer uses it directly instead
  of fetching from GitHub. Standard one-liner behaviour is unchanged.
- **README Windows section rewrite** — three clearly-numbered install
  options (installer zip → PowerShell one-liner → fully manual) and an
  explicit note that the `.qlplugin` file extension only works once
  QuickLook is installed. The "Download for Windows" button now points
  at the installer zip.

## [1.7.2] — 2026-05-14

### 🐛 Fixed

- **Sparkle "An error occurred while launching the installer"** — sandboxed
  app couldn't reach Sparkle's installer-launcher XPC service. The Sparkle SPM
  target only embeds `Installer.xpc` / `Downloader.xpc` inside the framework;
  macOS only honours mach-service lookups when those bundles live at
  `Contents/XPCServices/` of the host app. The release workflow now promotes
  them and re-signs with Developer ID, and the host's `mach-lookup` entitlement
  uses the framework's stock identifiers (`org.sparkle-project.InstallerLauncher`
  and `org.sparkle-project.DownloaderService`) instead of the
  `$(PRODUCT_BUNDLE_IDENTIFIER)-sp*` aliases which nothing was renaming.
- **Settings toggles not applying to the Quick Look preview** — the QL
  extension cached `SettingsStorage` once at process launch. macOS keeps the
  extension process warm across previews, so a toggle flipped in the main
  app afterwards never propagated. `preparePreviewOfFile` now re-instantiates
  `SettingsStorage` on every invocation to pick up a fresh snapshot of the
  App-Group preferences.
- **"Quick Look not updating?" card needed precise chevron clicks** —
  replaced `DisclosureGroup` with a custom plain-style `Button` header so
  the entire row (icon + title + subtitle + chevron) is the tap target,
  with a rotating chevron animation.

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
