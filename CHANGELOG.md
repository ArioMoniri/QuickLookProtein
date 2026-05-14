# Changelog

All notable changes to QuickLookProtein are recorded here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com); this project does not strictly
adhere to SemVer because version numbers are driven by upstream releases.

## [1.7.21] — 2026-05-14

### 🆕 Added — Live preview tiles in Windows Settings

- **WebView2 live preview grid** in the Settings app, the missing
  parity piece with the macOS app. The Mac settings panel has always
  shown ten little 3D preview tiles (one per format) so users can
  immediately see how their settings affect rendering. The Windows
  Settings app now has the same: a row of format buttons (PDB / CIF
  / SDF / MOL / MOL2 / XYZ / GRO / CUBE / PQR / VASP), each loading
  a bundled sample into a single WebView2 panel using the same
  `3Dmol.js` + `viewer.html` the plugin uses.
- **Settings honored in preview**. The preview reads the same
  registry hive the plugin reads on every Space-bar press, so
  flipping a setting in the Settings UI → clicking *Reload* renders
  the change instantly. No round-trip to QuickLook needed to A/B
  the look.
- **Sample files bundled** as `<Content Include>` items in
  `QuickLookProtein.Settings.csproj`: `6oc6.pdb`, `1565673.cif`,
  `PQQ.sdf`, `methane.mol`, `caffeine.mol2`, `benzene.xyz`,
  `water.gro`, `water.cube`, `methane.pqr`, `diamond.vasp`. All
  reused from the macOS app's `Assets/` folder via `<Link>` so
  there's a single source of truth — no duplicate sample data.
- **WebView2 NuGet dependency** added to `QuickLookProtein.Settings.csproj`
  pinned to the same `1.0.2792.45` the plugin uses. The same
  `CopyWebView2LoaderNative` MSBuild target promotes
  `WebView2Loader.dll` into the output so the .NET Framework auto-
  deploy gap is closed for Settings too.
- **Window size** bumped to 900 × 780 (up from 780 × 640) to make
  room for the preview panel without cramping the existing left/right
  column layout.

## [1.7.20] — 2026-05-14

### 🪟 Windows — diagnostics & integration pass

User reported v1.7.18's Setup.exe runs through cleanly but Space-bar
still shows .pdb files as raw text. This release focuses on making
the failure observable instead of mysterious, and on finishing the
"feel like a real Windows app" loop.

- **Plugin diagnostic log**.
  [Windows/QuickLookProtein.Plugin/PluginLog.cs](Windows/QuickLookProtein.Plugin/PluginLog.cs)
  writes a trace to `%LocalAppData%\QuickLookProtein\plugin.log` on
  every IViewer lifecycle call (Init / CanHandle / Prepare / View /
  Cleanup) and on every exception in the WebView2 load path.
  Auto-rotates at 1 MB. If the file is *missing* after a Space-bar
  attempt, the host (QL-Win) never even called us — meaning the DLL
  failed to load and `%LocalAppData%\QuickLook\App.log` has the
  TypeLoadException details.
- **Settings auto-launch on first install**. `install.ps1` detects
  a fresh install (Settings folder didn't exist) and opens
  `QuickLookProtein.Settings.exe` after the install completes.
  Upgrades stay silent so a re-run from the installer zip doesn't
  keep popping windows.
- **Add/Remove Programs entry**. New `Register-AddRemoveProgramsEntry`
  step in `install.ps1` writes the per-user
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\QuickLookProtein`
  key with `DisplayName`, `DisplayVersion`, `Publisher`,
  `InstallLocation`, `DisplayIcon`, and an `UninstallString` pointing
  at a generated `uninstall.ps1` that wipes the plugin folder, the
  thumbnail-handler registry entries, the Start Menu shortcut, and
  the Settings install dir. QuickLookProtein now appears in
  **Settings → Apps → Installed apps** like any other Windows app.
- **Diagnostics card in Settings**. New section in the Settings UI
  with three buttons: *Open plugin log*, *Open QuickLook log*,
  *Restart QuickLook tray*. The restart button goes through the same
  three-strategy escalation as install.ps1 (CloseMainWindow → Stop
  → taskkill) and re-launches QuickLook from the standard install
  location.
- **README terseness pass**. Windows install section trimmed to one
  sentence + one button. PowerShell one-liner, installer zip, manual
  install, troubleshooting all moved under a single `<details>`
  block so the surface area on the first scroll is *download → run*.

## [1.7.19] — 2026-05-14

### 🆕 Added — Mac info overlay extras

- **Info overlay fields are now per-field configurable**. The pill at
  the top-left of every preview used to be a fixed
  `filename · atoms · chains · format`. Now each piece is its own
  toggle in *Settings → Info overlay fields*: file name, atom count,
  chain count, file format (the originals, all default ON), plus four
  new fields default OFF:
  - **Residue count** — unique `(chain, resi, resn)` tuples.
  - **Element breakdown** — top 4 most abundant elements with counts,
    e.g. *"C:120 N:36 O:30 H:24"*.
  - **Molecular weight** — sum of IUPAC 2021 standard atomic masses
    over all atoms; auto-formats Da vs kDa above 1000.
  - **Bond count** — derived from 3Dmol's per-atom `bonds` arrays,
    halved (each bond is listed twice).
  - **PDB title** — first `TITLE` record from the PDB header, parsed
    in Swift before passing the file to 3Dmol, truncated to 60 chars
    in the overlay.
  All fields gated on the master "Show info overlay" master toggle.
- **Multi-file Quick Look behaviour setting** in Settings. Two modes:
  - *Separate windows (default)* — what you already get; QuickLook's
    own `<` `>` arrows navigate between selected files.
  - *Merge all in same folder* — placeholder for the planned QL-
    extension feature where the preview also pulls in every other
    supported structure in the file's folder and overlays them in
    one 3Dmol scene. Stored in user defaults; the QL extension
    will honour it in a later release once the sibling-read
    sandbox-permission story is clarified.

## [1.7.18] — 2026-05-14

### 🐛 Fixed

- **Settings app binaries weren't actually shipping** in v1.7.17. The
  workflow built the Settings WPF project to `build/settings/` and
  copied the output into the Setup.exe staging folder, but:
  - the Inno Setup `[Files]` block had no `Source:` entries for
    `QuickLookProtein.Settings.exe` / `.exe.config`, so Inno Setup
    compiled them out of the installer; and
  - the installer-zip staging block didn't even reference the
    Settings build output, so users grabbing the zip never saw the
    new control panel.
  Verified by `unzip -l` on the v1.7.17 installer zip - it only had
  the 4 files from before the Settings work. Fixed by adding the
  explicit `Source:` lines (with `skipifsourcedoesntexist` so the
  build doesn't break if a future runner image stops emitting one
  of them) and a parallel `Get-ChildItem` copy in the installer-zip
  step.

## [1.7.17] — 2026-05-14

### 🆕 Added — Windows feature parity

- **QuickLookProtein Settings.exe** — full WPF settings app for the
  Windows side, with the same controls as the macOS settings panel:
  - **Atom display style per format** for all 12 supported file types
    (PDB / CIF / SDF / MOL / MOL2 / XYZ / GRO / CUBE / PQR / VASP /
    CDJSON / MMTF). Choose between Cartoon / Stick / Sphere / Line.
  - **Color scheme** — Spectrum / Chain / Element / Secondary
    structure / Amino acid.
  - **Rotation speed** — Off / Slow / Medium / Fast.
  - **Default zoom** — Auto / Tight / Normal / Wide.
  - **Background color** — Windows ColorDialog picker, with a
    swatch preview and a "Transparent" reset.
  - **Rendering toggles** — Smart protein + ligand styling, Show
    molecular surface, Hide hydrogens, Show unit cell (CIF), Show
    info overlay.
  - Dark themed UI, card-based layout, About / Tips / Trouble
    sidebar with "Open GitHub" + "Open plugin folder" actions.
  - No "Save" button — every change persists immediately to the
    same registry hive the plugin reads on the next preview, so a
    toggle flipped here shows up the next time you tap Space in
    Explorer.
- **`Windows/Shared/SettingsStore.cs`** — single source of truth for
  the Windows settings. File-linked into both `QuickLookProtein.Plugin`
  and `QuickLookProtein.Settings` so neither project can drift from
  the other. Persists everything under
  `HKCU\Software\QuickLookProtein\Settings`, matching the cross-
  process semantics of macOS's App Group UserDefaults.
- **Start Menu shortcut** "QuickLookProtein Settings" written by
  `install.ps1`'s new `Install-SettingsApp` step. Per-user, no admin
  needed. Setup.exe bundles `QuickLookProtein.Settings.exe` and its
  dependencies into the installer payload.

### 🪟 Plugin integration

- **`MoleculePanel.FillTemplate`** now reads every template
  placeholder (`{ATOM_STYLE}`, `{COLOR_SCHEME}`, `{BG_COLOR}`,
  `{ROTATION_SPEED}`, `{ZOOM_FACTOR}`, the boolean toggles, …)
  from `SettingsStore` instead of hardcoded values, so a Settings-
  app change immediately affects the next Space-bar preview without
  restarting QuickLook.

## [1.7.16] — 2026-05-14

### 🆕 Added — thumbnail completeness pass

- **VASP / POSCAR parser**. Handles both old (no element line) and
  new (element symbols on line 6) VASP formats, fractional + Cartesian
  coordinate modes, optional "Selective dynamics" line, scale factor.
  Multiplies fractional coords by the lattice matrix to get Ångströms
  so the renderer's existing scale logic applies unchanged.
- **CDJSON parser**. Hand-rolled scanner over the ChemDoodle JSON
  `"a":[ ... ]` atom array - reads `x`/`y`/`z`/`l` fields without
  pulling in a JSON NuGet. Atom-count capped via the shared
  `MaxAtoms = 5000` so a hostile file can't stall thumbcache.
- **Cartoon-ribbon renderer for proteins**
  ([Windows/QuickLookProtein.Thumbnail/RibbonRenderer.cs](Windows/QuickLookProtein.Thumbnail/RibbonRenderer.cs)).
  When ≥10 alpha-carbon atoms in standard amino-acid residues are
  found, the thumbnail switches from CPK to a Catmull-Rom-splined
  tube through the CA backbone, colored N→C with a 3Dmol-style
  spectrum scheme. Same isometric pose + dark background as the
  CPK path, so a folder of mixed proteins and small molecules
  reads consistently. Matches what the macOS QLThumbnail.appex
  does in Swift.
- **Sniff-format** now recognises VASP (single-float line 2 + three
  three-float lines) and CDJSON (`"a":[...] + "l"` markers), so even
  renamed-extension files thumb correctly.

### 🪟 Windows

- **Augmented PDB parser** to capture atom name, residue name, chain
  ID, and residue sequence number. Required for protein-backbone
  detection in the new ribbon renderer; ignored by the CPK path.

### 📝 Intentionally not done

- **MMTF thumbnails** dropped from the registered extensions list.
  Parsing MMTF needs either ~500 KB of `MessagePack-CSharp` NuGet
  baggage loaded into every thumbnail-cache process or ~300 LoC of
  hand-rolled binary parser. Neither is worth shipping for a format
  that's vanishingly rare in practice. The Space-bar QuickLook
  preview still handles `.mmtf` via 3Dmol.js's JavaScript-side
  parser — only thumbnails fall back to the generic file icon.

## [1.7.15] — 2026-05-14

### 🐛 Fixed

- **Thumbnail handler registration was binding to a wrong assembly
  version**. `install.ps1` hard-coded `Version=0.0.0.0` in the
  `Assembly` value of the InProcServer32 key, but MSBuild defaults
  the actual DLL to `1.0.0.0`. mscoree's COM-to-CLR bridge couldn't
  find a matching type, Explorer fell back to the generic icon.
  install.ps1 now reads the version + culture + public-key-token
  directly from the DLL via `Reflection.AssemblyName.GetAssemblyName`
  and writes the actual `FullName`. This is the kind of latent bug
  you only catch by reading what the registry says vs. what the
  loader does, hence the audit.

### 🆕 Added

- **CIF / mmCIF parser** in the thumbnail provider. Walks the
  `_atom_site` loop, locates the `Cartn_x/_y/_z` and `type_symbol`
  columns by name (so different small-mol / mmCIF column orders all
  work), reads up to 5,000 atoms.
- **Gaussian Cube parser** in the thumbnail provider. Skips the
  voxel-axis header and parses the atom block, converting Bohr
  radii to Ångströms so the renderer's existing scale heuristics
  apply unchanged. Compact atomic-number → element table covering
  the common biology / chemistry set.
- **SniffFormat** now detects CIF (looks for `data_` + `_atom_site`)
  and Cube (looks for the counts-line + 3 axis-lines pattern), so
  even renamed-extension files thumb correctly.

## [1.7.14] — 2026-05-14

### 🐛 Fixed

- Compile error in the new thumbnail project — `WTS_ALPHATYPE` enum
  and `IThumbnailProvider` / `IInitializeWithStream` interfaces were
  internal but referenced by the public `MoleculeThumbnailProvider`'s
  public method signatures. C# refused with `CS0051: Inconsistent
  accessibility`. Promoted them to public; COM consumers don't
  observe C# accessibility anyway.

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
