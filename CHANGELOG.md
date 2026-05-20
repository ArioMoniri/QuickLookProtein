# Changelog

All notable changes to QuickLookProtein are recorded here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com); this project does not strictly
adhere to SemVer because version numbers are driven by upstream releases.

## [1.7.72] — 2026-05-20

### 🪟 Diagnostic — cctor sentinel file

User reported that after a clean 1.7.71 install, `plugin.log` still doesn't appear when QL-Win previews a `.pdb`. The follow-up x86-PowerShell diagnostic confirmed our DLL loads cleanly under 32-bit (matching QL-Win's actual bitness on their machine), `GetTypes()` returns all 16 expected types, and `Activator.CreateInstance(Plugin)` succeeds — so the assembly itself is structurally fine for QL-Win to discover. The failure is somewhere in QL-Win's discovery loop, *not* in our plugin's code.

To prove this from the QL-Win process side rather than from PowerShell, `Plugin`'s static cctor now writes a `cctor.txt` sentinel file at `%LocalAppData%\QuickLookProtein\cctor.txt` via raw `File.WriteAllText`, bypassing `PluginLog` entirely. The file records the timestamp, host process PID + exe path, bitness, and the plugin's assembly version. After installing 1.7.72 and pressing Space on a `.pdb`:

- If `cctor.txt` **exists**, QL-Win is touching our type but never reaching `Init()` — we look at QL-Win's discovery internals.
- If `cctor.txt` **doesn't exist**, QL-Win isn't loading our DLL at all — we look at QL-Win's plugin folder scanning, caches, or version compatibility.

No functional change to the plugin's render path; purely a diagnostic instrumentation aid.

## [1.7.71] — 2026-05-19

### 🪟 Windows hotfix⁴ — ship the bitness-aware native loader into the .qlplugin, then pin it

The 1.7.70 fix flipped the plugin DLL to AnyCPU but left two gaps that would have surfaced after `Plugin.Init()` finally got called on a 32-bit QL-Win host:

- **Gap 1 — release packaging missed the `runtimes/` subtree.** The csproj's `CopyWebView2LoaderNative` target now lays down both `runtimes/win-x86/native/WebView2Loader.dll` and `runtimes/win-x64/native/WebView2Loader.dll` (so the AnyCPU `Microsoft.Web.WebView2.Core` wrapper can pick the matching one at runtime), but `release.yml`'s `.qlplugin` package step copied only top-level files via `Get-ChildItem -File` without `-Recurse`. The subtree never reached the zip, so a 32-bit QL-Win install would still hit `BadImageFormatException` when WebView2 tried to load its native bridge. Now `Copy-Item -Path "build/plugin/runtimes" -Destination $stage -Recurse` puts both bitness loaders inside the `.qlplugin`.
- **Gap 2 — Windows' default DLL search order doesn't include the plugin folder.** Even with the right `WebView2Loader.dll` shipped, when `Microsoft.Web.WebView2.Core` P/Invokes `"WebView2Loader.dll"` (no path), Windows looks in `AppDomain.BaseDirectory` (= `QL-Win.exe`'s folder), system dir, `PATH` — never our plugin folder. So `Plugin`'s static constructor now pre-pins the correct loader: it computes `runtimes/win-{x86|x64}/native/WebView2Loader.dll` based on `IntPtr.Size`, `LoadLibraryW`s it explicitly, and falls back to the flat-folder `WebView2Loader.dll` if the bitness-specific path is missing. With the DLL in the process's loaded-module cache, the managed wrapper's P/Invoke later resolves against the already-loaded handle instead of running through search order.

The two gaps combined are why 1.7.70 wasn't quite the end of this — 1.7.71 closes both. After install, the on-disk layout under `%LocalAppData%\QuickLook\plugins\QuickLookProtein\` will include `runtimes\win-x86\native\WebView2Loader.dll` and `runtimes\win-x64\native\WebView2Loader.dll` alongside the existing flat-folder DLLs.

## [1.7.70] — 2026-05-19

### 🪟 Windows hotfix³ — `BadImageFormatException`, plugin DLL was x64-only

- **Symptom**: with 1.7.69 installed, pressing <kbd>Space</kbd> on a `.pdb` *still* showed the raw text dump. `plugin.log` still didn't exist. The diagnostic block from the README finally surfaced the real loader error from PowerShell: *"Could not load file or assembly 'QuickLook.Plugin.Protein.dll' or one of its dependencies. An attempt was made to load a program with an incorrect format."* That's `BadImageFormatException`, the canonical "your DLL's bitness doesn't match my process" error.
- **Root cause**: `Windows/QuickLookProtein.Plugin/QuickLookProtein.Plugin.csproj` pinned `<PlatformTarget>x64</PlatformTarget>`, which writes the PE32+ x64-only marker into the DLL's COFF header. QL-Win.exe ships AnyCPU and on the user's machine was running as **32-bit (x86, WOW64)**. The CLR refused to load an x64-marked DLL into a 32-bit process and threw the load error silently from QL-Win's plugin discovery → our plugin never showed up in QL-Win's IViewer registry → Space-bar fell through to the text viewer. *No amount of AssemblyResolve / static cctor / type-decoupling work from 1.7.68 / 1.7.69 could have helped*: the assembly itself was being rejected at the PE-header check, *before* any IL or metadata was read.
- **Fix**: flip the plugin's `<PlatformTarget>` to `AnyCPU` so the CLR can host the assembly in either bitness. To keep the WebView2 native bridge happy in both, the `CopyWebView2LoaderNative` MSBuild target now also lays down **both** `runtimes/win-x86/native/WebView2Loader.dll` and `runtimes/win-x64/native/WebView2Loader.dll` (the AnyCPU managed wrapper picks the matching one at runtime via `Environment.Is64BitProcess`). The flat-folder fallback (sibling `WebView2Loader.dll` next to the plugin DLL) is preserved with the x64 copy so 1.7.69-and-earlier install layouts still resolve.
- **Same fix for `QuickLookProtein.Thumbnail.csproj`**: Explorer's thumbnail-cache pipeline includes a 32-bit COM surrogate (`dllhost.exe`) for legacy app compat, which would have hit the same `BadImageFormatException` on x64-only thumbnail DLLs. `PlatformTarget=AnyCPU` there too.
- **Diagnostic block in the README will now actually work**: the FileVersion stamping that didn't reach the binary in 1.7.69 (MSBuild cascade was masked by explicit `<AssemblyVersion>`) lands properly here — `(Get-Item ...).VersionInfo.FileVersion` will report `1.7.70` after this install.

## [1.7.69] — 2026-05-19

### 🪟 Windows hotfix² — plugin still not picked up after 1.7.68

- **Symptom**: user on the freshly-installed 1.7.68 Setup.exe ran the diagnostic block from the README and found that `%LocalAppData%\QuickLookProtein\plugin.log` did not exist after pressing <kbd>Space</kbd> on a `.pdb` file. Plugin folder was complete, WebView2 Runtime + DLLs present, QL-Win running — but `Plugin.Init()` was never called. Space-bar still rendered raw text.
- **Root cause** *(refining the 1.7.68 diagnosis)*: QL-Win discovers IViewer implementations via `Assembly.LoadFrom(...)` + `GetTypes()`. The CLR materialises `Plugin`'s type metadata, which includes the declared types of all its fields. `Plugin` had `private MoleculePanel? _panel;` — a typed field. The CLR followed that reference, loaded `MoleculePanel`, saw its `<wv2:WebView2>` XAML reference, tried to resolve `Microsoft.Web.WebView2.Wpf`, **failed because the AssemblyResolve hook was inside `Plugin.Init()` and `Init()` is only reached *after* `GetTypes()` succeeds**, and surfaced a `ReflectionTypeLoadException`. QL-Win caught it, blacklisted our DLL, and moved on. `Init()` never ran → no `plugin.log` line → user saw text.
- **Fix in three parts**:
  1. **Type-decoupling.** `Plugin._panel` is now `object?` instead of `MoleculePanel?`. `MoleculePanel` no longer appears in `Plugin`'s metadata, so `GetTypes()` returns `Plugin` cleanly without touching WebView2. `MoleculePanel` is only loaded when `View()` calls a `[MethodImpl(MethodImplOptions.NoInlining)]` helper that constructs it — the JIT for that helper is deferred until the helper is entered, by which point the resolver below is already attached.
  2. **AssemblyResolve in static cctor.** Moved the resolver attach from `Plugin.Init()` into `static Plugin()`. The CLR fires the static constructor when `Activator.CreateInstance(typeof(Plugin))` runs — strictly before `Init()`, and strictly before `View()`. So `Microsoft.Web.WebView2.*` resolution requests during `MoleculePanel` inflation always have the hook in scope.
  3. **Identifiable FileVersion.** `Windows/QuickLookProtein.Plugin/QuickLookProtein.Plugin.csproj` now stamps the DLL's `FileVersion` and `InformationalVersion` from `MARKETING_VERSION` at release-build time (via `dotnet build /p:Version=${VERSION}` in `release.yml`). Previous releases all shipped a `1.0.0.0` plugin DLL, which made the diagnostic check `(Get-Item ...).VersionInfo.FileVersion` useless for confirming which build a user was actually on. From 1.7.69 onward the diagnostic shows the real release number.

## [1.7.68] — 2026-05-19

### 🪟 Windows hotfix — Space-bar showed raw text instead of the 3D preview

- **Symptom**: after a successful `QuickLookProtein-Setup.exe` install, pressing <kbd>Space</kbd> on a `.pdb` (or any other supported extension) opened a plain-text dump of the file's ATOM lines instead of the 3Dmol viewer. QL-Win's text-fallback viewer was kicking in — a sign that our plugin had failed to load.
- **Root cause**: QL-Win loads plugin DLLs via `Assembly.LoadFile()`, which puts the assembly into the *Load* (not *LoadFrom*) context. That means the CLR's standard probing paths (`AppDomain.BaseDirectory` + GAC) are the only places it'll look for transitive dependencies — **not** the plugin's own directory. When QL-Win called `Plugin.View()` and the WPF runtime tried to inflate `MoleculePanel.xaml` (which carries `xmlns:wv2="clr-namespace:Microsoft.Web.WebView2.Wpf;assembly=Microsoft.Web.WebView2.Wpf"`), the resolver couldn't find `Microsoft.Web.WebView2.Wpf.dll` in `%LocalAppData%\Programs\QuickLook\` and threw `XamlParseException`. QL-Win caught it, blacklisted our plugin for that file, and fell back to text.
- **Fix**: `Plugin.Init()` now attaches an `AppDomain.AssemblyResolve` handler that probes the plugin's own directory (`%LocalAppData%\QuickLook\plugins\QuickLookProtein\`) for the requested assembly + `.dll` and returns `Assembly.LoadFrom(...)` on hit. WebView2.Core / .Wpf / .WinForms (and anything else we may add as a transitive dep) resolve in one place. The handler skips `*.resources` so we don't accidentally shadow localised satellite assemblies QL-Win or another plugin owns, and swallows its own exceptions so a bad probe never crashes the AppDomain.
- **Diagnostic improvement**: a `Resolved 'X' -> path` line lands in `plugin.log` for every successful late-bind, so future "Space-bar shows raw text" reports can be triaged from the Settings → Diagnostics → Open plugin log button in one click.

## [1.7.67] — 2026-05-19

### 🛠️ Hotfix — Sparkle update from 1.7.65 to 1.7.66 failed

- **Root cause**: 1.7.66 set `CFBundleName=QLProtein2` (intended to fit Apple's 15-char menu-bar limit). Sparkle's installer compares `CFBundleName` between the installed app (`QuickLookProtein`, from 1.7.65) and the downloaded update (`QLProtein2`, from 1.7.66). When the names diverge Sparkle bails with **"An error occurred while launching the installer"** — its safeguard against accidentally installing a different app's update over yours.
- **Fix**: revert `CFBundleName` to `$(PRODUCT_NAME)` (still resolves to `QuickLookProtein`). The full "QuickLookProtein2" rebrand now rides exclusively on `CFBundleDisplayName`, which Finder, the menu bar, About panel, and "Get Info" all use, and which Sparkle does *not* consult for the host-vs-update name check. Users on 1.7.65 who already failed to update to 1.7.66 will now be offered 1.7.67 and the install will succeed.

### 📝 Appcast — release notes pane now shows the actual changelog

- **Symptom**: the "What's New" pane in Sparkle's update dialog rendered as essentially empty — only a single "See the GitHub release for full notes" sentence.
- **Cause**: `scripts/update-appcast.py` always emitted that stub string as the `<description>`; the real CHANGELOG.md entry never reached the appcast.
- **Fix**: the script now pulls the `## [<version>]` section from `CHANGELOG.md`, renders it through a small stdlib-only Markdown-to-HTML converter (H3, bullet lists, inline `**bold**` / `` `code` `` / `[link](url)`), and writes that as the appcast item's description. Future Sparkle updates show the real notes inline.

## [1.7.66] — 2026-05-19

### ✨ Rebrand to **QuickLookProtein2** (display name only)

- **`CFBundleDisplayName` = `QuickLookProtein2`** in `Xcode/QuickLookProtein/Info.plist`; `CFBundleName` shortened to `QLProtein2` to fit Apple's 15-char menu-bar recommendation. **`PRODUCT_NAME`, `CFBundleIdentifier`, and the Sparkle `SUFeedURL` are unchanged**, so the on-disk bundle stays `QuickLookProtein.app` and Sparkle keeps replacing existing installs in place — no orphaned updates.
- **User-visible sweep**: About panel hero + sidebar + status-line subtitle + "Enable" toggle row + rendering description in `ContentView.swift`; QL extension's "disabled" placeholder in `QLExtension/PreviewViewController.swift`; appcast channel title + future-item title prefix in `docs/appcast.xml` and `scripts/update-appcast.py`; landing page in `docs/index.html`.
- **Windows parity**: Settings window title `QuickLookProtein2 Settings`, About card emphasising Jethro Hemmann as the original author + a direct link to the upstream repo, MessageBox dialog titles, Add/Remove Programs `DisplayName`, Inno Setup `AppName`. Registry keys, on-disk paths, and the QL-Win plugin folder name kept as `QuickLookProtein` so upgrades land on the same entry.

### 🏛️ Credits — original author emphasis

- About panel (Mac + Windows) now leads with **"Originally built by Jethro Hemmann (2021–2022) — the original QuickLookProtein"** in semibold, followed by a clickable link to <https://github.com/JethroHemmann/QuickLookProtein>. The "Extended by Ariorad Moniri (2026) as QuickLookProtein2" line sits below, with the fork repo linked underneath.
- README rebranded heading + Credits section reorder Jethro first; new explanatory subheader directly under the title makes the relationship to the original explicit.

### 🛠️ Windows — fix Settings.exe "infinite respawn" on first install

- **Root cause**: `Windows/QuickLookProtein.Settings/MainWindow.xaml` references `<wv2:WebView2 assembly=Microsoft.Web.WebView2.Wpf>`, which the XAML parser resolves at `InitializeComponent` time. The previous `Windows/install.ps1` explicitly excluded `Microsoft.Web.WebView2.*` and `WebView2Loader.dll` from the per-user install dir, and the Inno Setup `[Files]` block in `release.yml` only declared the named Settings.exe + .config files — so the four WebView2 DLLs never shipped. Settings.exe crashed with `XamlParseException` on launch; from the user's perspective the window flashed and closed, looking like an "infinite respawn" if they retried from the Start Menu.
- **Fix**: removed the exclusion in `install.ps1`, added a `runtimes\win-x64\native\WebView2Loader.dll` fallback lift for cases where MSBuild didn't promote it, and added explicit `Source:` entries in the Inno Setup `.iss` for `Microsoft.Web.WebView2.Core.dll`, `Microsoft.Web.WebView2.Wpf.dll`, `Microsoft.Web.WebView2.WinForms.dll`, and `WebView2Loader.dll`.
- **Defence in depth**: `App.xaml.cs` now wires `DispatcherUnhandledException` + `AppDomain.UnhandledException` + a try/catch around `base.OnStartup`, so a future XAML-parse / missing-DLL fault shows a MessageBox naming the failure instead of vanishing silently. Added a named single-instance Mutex so accidental double-clicks during a crash-loop activate the existing window instead of spawning N transient processes. Per-step try/catch in `MainWindow_Loaded` so a registry hiccup or WebView2 runtime miss surfaces in the status bar rather than tearing down the UI.

### 🍺 Homebrew cask

- New `Casks/quicklookprotein.rb` — production-grade: real SHA256 against the versioned DMG, versioned URL, `livecheck :github_latest`, `auto_updates true` so Brew doesn't fight Sparkle for control of `/Applications`, `depends_on macos: :big_sur`, alphabetised `zap trash:` array that wipes Sparkle's persisted prefs plus every extension's plist.
- Install via personal tap: `brew tap ariomoniri/quicklookprotein https://github.com/ArioMoniri/QuickLookProtein` then `brew install --cask quicklookprotein`.
- README gets a Homebrew Cask badge + a Homebrew SVG download button matching the existing macOS/Windows pair (`docs/download-homebrew.svg`). Mac Settings About card surfaces the one-line install command under the credits row (gated on macOS 12+ for `.textSelection(.enabled)`).

### 🤖 CI

- New `.github/workflows/ci-validate.yml` — runs on every push to `main` / `feature/**` and on PRs. Three parallel jobs: **macos-15 + Xcode 16 xcodebuild** (no signing) of the main app, **dotnet build** of the Plugin + Thumbnail + Settings csprojs on `windows-2022` (with QuickLook.Common.dll fetched from QL-Win's release the same way `release.yml` does), and **brew style + brew audit** of the cask via a synthetic local tap.
- The Windows job explicitly asserts that `QuickLookProtein.Settings.exe` plus all four WebView2 DLLs land in the build output, so a regression that reintroduces the respawn bug fails CI at PR time. The macOS job asserts `CFBundleDisplayName == QuickLookProtein2` so the rebrand doesn't silently drift.

## [1.7.32] — 2026-05-14

### 🆕 Added — cryo-EM density maps (.ccp4 / .mrc / .map)

- **Native binary parser for CCP4/MRC/MAP cryo-EM densities** in
  `Xcode/Shared/SharedFunctions.swift` (`convertCCP4ToCube`).
  Reads the 1024-byte fixed-width header (auto-detects little- vs
  big-endian via the `MACHST` field at byte 212), pulls grid
  dimensions, voxel spacing, axis order (`MAPC/R/S`), and the
  float32 voxel data, then emits a Gaussian Cube text payload with
  the negative-natoms volumetric-only convention.
- **Downsampling**: maps over 4M voxels (~256³+) get strided so
  the resulting Cube text stays under 30 MB. Quick Look's webview
  can't realistically render every voxel of a 512³ map and we'd
  rather show *some* preview than time-out.
- **Pipeline composes naturally**: detection runs before the
  computational-chem and bio-assembly pre-passes, sets
  `workingFormat = "cube"`, and forces `{CUBE_ISOSURFACE}` ON in the
  viewer template. The existing 3Dmol cube-isosurface JS (added in
  v1.7.30) then renders the volume.
- **UTI declarations** for `.ccp4` / `.mrc` / `.map` in the main
  app's Info.plist and the QL extension's `QLSupportedContentTypes`.
- **Preview cap** lifted to 500 MB for cryo-EM extensions
  (text formats stay at the 25 MB ceiling). A 256³ float32 map
  occupies 67 MB on disk; even 512³ at 537 MB is now accepted, with
  the downsampler taking the brunt.
- **Settings**: new `cryoEMRender` (default ON) and `cryoEMSigma`
  (default 2.5) toggles in Mac side; UTI registration only — Windows
  parity is queued for a follow-up since the cryo-EM use case is
  almost entirely macOS in practice (CryoSPARC / RELION / cryoSPARC
  output).

### 🪟 Windows

- Settings UI gains the matching toggles but the binary parser
  isn't yet ported to C# (.ccp4/.mrc/.map files still fall through
  to QL-Win's text-viewer fallback). Queued.

## [1.7.31] — 2026-05-14

### 🆕 Added — biological assembly expansion

PDB and mmCIF entries deposit the *asymmetric unit*, but the
biological-assembly (the actual functional molecule — tetramer of
hemoglobin, symmetric dimer of a coiled-coil, etc.) is built by
applying symmetry-operator transformations declared in
`REMARK 350 BIOMT*` (PDB) or `_pdbx_struct_oper_list` (mmCIF).
Most molecular viewers default to showing the assembly. We didn't
— previews only ever showed the asymmetric unit.

- **New `bioAssembly` setting** (default ON, Mac + Win). When on,
  `prepare3DmolHTML` runs a Swift pre-pass that:
  1. Parses every `REMARK 350 BIOMTn N  m11 m12 m13  t` row into a
     3×4 rotation+translation matrix.
  2. For CIF: walks the `_pdbx_struct_oper_list` loop, extracts
     `matrix[i][j]` + `vector[i]` columns by name.
  3. Reads every `ATOM` / `HETATM` (or `_atom_site` row),
     transforms `(x, y, z)` by each operator, and emits a
     multi-MODEL PDB.
  4. 3Dmol parses that as separate models stacked in one scene.
- **Skips no-op cases**: files with only the identity operator
  pass through unchanged. Files without assembly records pass
  through unchanged.
- **CIF → PDB-shaped conversion** in
  [SharedFunctions.swift:cifAtomsAsPdb](Xcode/Shared/SharedFunctions.swift)
  is lossy (drops alt-conf, anisou, the auth_* vs label_* distinction
  collapses to auth_*) but coords / chain / residue identity
  round-trip cleanly, which is all the assembly expansion needs.
- The pre-pass runs *before* the computational-chem parser so the
  pipeline composes: bio-assembly first, then comp-chem
  (mutually exclusive — comp-chem outputs don't have BIOMT
  records).

### 🪟 Windows

- `SettingsStore.cs` mirrors `BioAssembly` (default ON) under the
  same registry hive.
- `MoleculePanel.FillTemplate` forwards the placeholder. Note: the
  Swift-side assembly expander runs in the Mac QL extension; the
  Windows plugin currently passes the placeholder through to the
  template but doesn't yet replicate the expansion in C# — for now
  Windows users on PDB/CIF still see the asymmetric unit. C# port
  of the expander is queued for a follow-up release.
- Settings WPF gains a "Biological assembly" checkbox in
  *Rendering options*.

## [1.7.30] — 2026-05-14

### 🆕 Added — auto-orient + cube isosurface + comp-chem parsers

- **Auto-orient by principal axes.** When the new `autoOrient`
  setting is on (default OFF), the viewer rotates so the molecule's
  longest principal axis is horizontal. Computed in JS via a 3×3
  covariance matrix + 10-round power iteration on the dominant
  eigenvector, then `viewer.rotate` yaw/pitch to align with the X
  axis. Deterministic canonical pose per file — nice for
  screenshots and batch consistency.
- **Cube isosurface rendering.** New `cubeIsosurface` setting
  (default OFF). When on AND the file is a Gaussian Cube, the viewer
  builds a `$3Dmol.VolumeData(text, 'cube')` and calls
  `viewer.addIsosurface` twice — once at `+0.02` in blue and once at
  `-0.02` in red, the canonical orbital-density paired-lobe look.
- **Gaussian / ORCA / QChem output parsing.** SharedFunctions.swift
  gains a new `parseComputationalChem` family that sniffs ORCA's
  *"CARTESIAN COORDINATES (ANGSTROEM)"* / Gaussian's *"Standard
  orientation"* / QChem's *"Standard Nuclear Orientation"* blocks
  out of the output text, picks the LAST block (= final optimization
  step), rewrites it as XYZ, and dispatches 3Dmol to its native XYZ
  parser. Also handles `.gjf` / `.com` Gaussian *input* files. The
  format dispatch in `prepare3DmolHTML` is reused so atom-style
  defaults and bond perception apply unchanged.
- **Periodic-table lookup** (`atomicNumberToElement`) covering the
  first 86 elements, used by Gaussian's atomic-number-based output
  format.

### 🪟 Windows

- `Windows/Shared/SettingsStore.cs` mirrors `AutoOrient` and
  `CubeIsosurface` toggles (default OFF) under the same HKCU hive
  the main plugin reads.
- `MoleculePanel.FillTemplate` forwards both placeholders.
- Settings WPF gains two new checkboxes in *Rendering options*.

## [1.7.29] — 2026-05-14

### 🆕 Added

- **Per-button toolbar visibility.** Each of the 8 interactive
  toolbar buttons (Stick / Line / Sphere / Cartoon / Surface /
  Color SS / Label αC / Recenter) is now an independent toggle
  in Settings. Useful on smaller previews; hide everything you
  don't use. Defaults all ON. Mac + Windows in parity.
- **Outline shading toggle.** Adds 3Dmol's per-style `outline:true`
  flag to every rendering style — thin dark border around atoms
  and bonds. Default OFF. Makes structures pop on light
  backgrounds. Mac + Windows.
- **B-factor / pLDDT coloring.** New `ColorScheme.bfactor` /
  `Bfactor` option (Mac + Windows). Auto-detects AlphaFold-style
  pLDDT confidence (every B-factor in [0, 100] with at least one
  ≥ 50) and uses 3Dmol's `roygb` gradient pinned at [50, 90]
  matching standard pLDDT conventions. Falls back to a min/max-fit
  `rwb` gradient on raw B-factors for X-ray structures.
- **Keyboard shortcuts in the preview.** Inside any QL preview:
  - `1`–`4` switch to Stick / Line / Sphere / Cartoon
  - `S` / `R` / `L` / `C` toggle Surface / Recenter / Label αC / Color SS
  - `Tab` cycles through visible style buttons
  Modifier keys (Cmd / Ctrl / Alt) and input fields are skipped
  so QL's own shortcuts (Cmd-W, spacebar) keep working.

## [1.7.28] — 2026-05-14

### 🐛 Fixed — DMG background actually renders this time

v1.7.27 promised a polished DMG background but shipped without one.
The release-job log showed
`::warning::DMG background generation failed - shipping without one.`
Root cause: the workflow used Python + Pillow to draw the PNG, but
Pillow isn't preinstalled on github-hosted macOS runners and the
`try: from PIL import …` fell through silently.

Fix: replaced with a one-shot Swift + CoreGraphics renderer that
ships with every macOS runner image, no `pip install` required.
Same 640×400 background — gradient + drop-arrow + "QuickLookProtein"
title + tagline — but drawn via `CGContext` / Core Text. Locally
verified producing a valid PNG before tagging.

The volume icon (`--volicon`) already worked in v1.7.27 — that's
why mounting the DMG showed the app icon on the disk. The empty
window-background was the only missing piece.

## [1.7.27] — 2026-05-14

### 🐛 Fixed — App Group regression introduced in v1.7.24

User reported v1.7.26 broke three things at once: Sparkle's
"Updater failed to start" dialog, Info-overlay field toggles that
didn't change anything in the preview, and Multiple-file preview
"Merge all in same folder" doing nothing. All three were the same
bug — codesign inspection of v1.7.26's parent .app showed the
App Group string as the literal
$(TeamIdentifierPrefix)group.com.ariomoniri.QuickLookProtein
instead of FF68N39FU5.group.com.ariomoniri.QuickLookProtein.

The "Embed Sparkle XPC services" step's parent re-sign passed the
raw Xcode/QuickLookProtein/QuickLookProtein.entitlements file to
codesign. Xcode normally expands $(TeamIdentifierPrefix) during
archive; passing the file directly to codesign bypasses that. The
literal unexpanded variable goes into the binary's entitlements
blob, App Group membership silently fails, and everything that
depends on the main app + extension sharing a UserDefaults
container (Sparkle's update flow, the info-overlay field setting,
the multi-file-mode setting) breaks at once.

Fix: parent re-sign now uses
`--preserve-metadata=entitlements,requirements` instead of
`--entitlements <file>`, keeping whatever Xcode's archive step
embedded (which has the variable already expanded).

### 🆕 Added — interactive 3Dmol toolbar inside Quick Look

The buttons 3Dmol.js's stock HTML helper shows
(Stick / Line / Sphere / Cartoon / Surface / Color SS / Label αC
/ Recenter) are now available inside every Quick Look preview,
not just in the standalone main app. Bottom-right pill toolbar,
flat row, light/dark theme aware, active-state highlight on the
currently-selected style.
- New `showControlsInPreview` setting (defaults ON) gates
  visibility. Toggle in Settings -> Rendering options.
- Wired through both code paths: the single-file
  prepare3DmolHTML and the merge-mode prepare3DmolHTMLMulti, plus
  the Windows plugin's MoleculePanel.FillTemplate and the Settings
  WPF live-preview tile.

### 🆕 Added — Windows Settings parity

- Windows/Shared/SettingsStore.cs gains ShowControlsInPreview
  (default ON), persisted under
  HKCU\Software\QuickLookProtein\Settings.
- QuickLookProtein.Settings.exe Rendering options card gains a
  "Show interactive controls" checkbox matching the macOS toggle.

### 🆕 Added — DMG visual polish

QuickLookProtein-1.7.27.dmg opens with a proper drag-to-Applications
window: app icon on the left, an arrow, an /Applications shortcut
on the right, "QuickLookProtein" title at the top, and the app's
own icon on the disk image itself instead of the generic white
volume icon. The background image is generated on the fly during
release via a small Python+Pillow step.

### ⚠️ For users currently on a broken release

Users stuck on v1.7.24 / v1.7.25 / v1.7.26 whose Sparkle updater
errors out need to download
[QuickLookProtein.dmg](https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein.dmg)
manually and drag-replace /Applications/QuickLookProtein.app once.
After that single swap, in-app Sparkle updates resume working.

## [1.7.24] — 2026-05-14

### 🐛 Fixed — Sparkle "An error occurred while launching the installer"

User got the dreaded "Update Error / An error occurred while
launching the installer" dialog when running the in-app updater
from v1.7.x. v1.7.2 supposedly fixed this by embedding the Sparkle
XPC services into `Contents/XPCServices/`, and `codesign -d
--entitlements` against v1.7.23 confirms both services are present
and signed — but they have **no entitlements at all**.

The "Embed Sparkle XPC services" workflow step was re-signing each
`.xpc` with `codesign --force --sign` and no `--entitlements`
argument. That strips any entitlements baked in by Sparkle. For a
sandboxed host, the Installer / Downloader services need specific
entitlements (sandbox + App Group + write-access to `/Applications/`
for the installer, sandbox + App Group + network.client for the
downloader). Without them, `xpc_connection_resume` fails on the
host side and Sparkle surfaces the generic "error launching
installer" message.

Fix:
- New entitlements files [Xcode/Sparkle/Installer.entitlements](Xcode/Sparkle/Installer.entitlements)
  and [Xcode/Sparkle/Downloader.entitlements](Xcode/Sparkle/Downloader.entitlements) following
  the Sparkle sandboxing guide.
- Workflow re-sign loop now picks the matching `.entitlements` file
  per service and passes it to `codesign --entitlements`, so the
  shipped XPC services have the entitlements they need.

### ⚠️ Action for users currently on a broken release

This fix only helps **future** Sparkle updates (from v1.7.24
onwards) because the broken installer-launcher is in the *currently
installed* app. If you're stuck on a release whose installer
launcher fails, download [QuickLookProtein.dmg](https://github.com/ArioMoniri/QuickLookProtein/releases/latest/download/QuickLookProtein.dmg)
manually and drag-replace `QuickLookProtein.app` in `/Applications`.
After that one manual swap, Sparkle will work normally.

## [1.7.23] — 2026-05-14

### 🆕 Added — multi-file merge mode (Mac)

v1.7.19 added a `multiFilePreviewMode` setting (Separate / Merge in
same folder) but the QL extension still only ever rendered one
file. This release actually wires up *Merge in same folder*:

- `Xcode/QLExtension/PreviewViewController.swift` checks the setting
  on each `preparePreviewOfFile`. When merge mode is on, it calls a
  new `collectMergeSiblings(forFileAt:)` helper that walks the
  parent directory, picks up every supported structure file the
  App-Sandbox lets us read, caps at 25 files / 5 MB each, and hands
  the bundle to a new `prepare3DmolHTMLMulti(htmlPath:files:options:)`
  builder. The original file always comes first so its extension
  still drives the default atom style, color scheme, etc.
- Multi-model rendering uses one `<script type="text/plain">` per
  sibling plus a JS array of `{id, format, name}` records the viewer
  iterates after loading the primary model. New `{EXTRA_MODELS_JSON}`
  and `{EXTRA_MODELS_HTML}` template placeholders. Single-file mode
  passes empty values so behaviour is identical to before.
- `viewer.selectedAtoms({})` replaces `model.selectedAtoms({})` so
  the atom-list smart-styling + info-overlay counts cover *all*
  loaded models. Falls back to the old single-model path on builds
  of 3Dmol where the viewer-level helper isn't available.
- Failed siblings (unreadable, parse error) are logged and skipped
  rather than blowing up the whole preview — the primary file plus
  whichever siblings did parse still render cleanly.
- Settings UI label updated to make it explicit this is the
  "scan sibling structures in this folder" mode, not a fake
  reimplementation of QuickLook's `<` / `>` arrows (those are
  built into macOS itself and unchanged).

### 🪟 Windows — info-overlay parity with Mac

The 9 info-overlay field toggles that shipped on macOS in v1.7.19
finally land on Windows:

- `Windows/Shared/SettingsStore.cs` gains 9 new bools, defaults
  matching the Mac (file name / atom count / chain count / format
  default ON; residue count / element breakdown / molecular weight
  / bond count / PDB title default OFF). Persisted under the same
  `HKCU\Software\QuickLookProtein\Settings` hive both processes
  read.
- `MoleculePanel.FillTemplate` reads every flag, forwards them
  through the new `{INFO_*}` template placeholders, and extracts
  the PDB TITLE record on the fly via a new `ExtractPdbTitle`
  helper (mirror of the Swift `extractPDBTitle`). `EscapeForJsString`
  pairs with the Swift `escapeForJSStringLiteral` so weird PDB
  titles can't break out of the JS literal.
- `QuickLookProtein.Settings.exe` gets an **Info overlay fields**
  card with 9 checkboxes, gated on the existing "Show info
  overlay" master toggle (visually disabled when off). The live-
  preview tile reads the same flags so users can A/B settings
  against a real render.

## [1.7.22] — 2026-05-14

### 🐛 Fixed

- **Live preview tiles in v1.7.21 couldn't find any samples** to load.
  The csproj's `<Content Include>` items did copy the sample files
  into `build/settings/SampleAssets/`, and the Settings.exe looked
  there at runtime, but the workflow's Setup.exe staging block and
  installer-zip block both used `Get-ChildItem -File` (top-level
  files only), so the `SampleAssets/` subfolder never made it into
  either bundle. Setup.exe shipped the `.exe` + `.config` + WebView2
  DLLs but no samples; every format button silently showed *"Sample
  files not bundled with this build."*
  Three fixes:
  - workflow Setup.exe staging now copies `build/settings/SampleAssets/`
    recursively into the staging dir.
  - Inno Setup `[Files]` block gets a new `Source: SampleAssets\*` entry
    with `recursesubdirs createallsubdirs skipifsourcedoesntexist`
    flags so the whole tree lands under `{app}\SampleAssets`.
  - `install.ps1`'s `Install-SettingsApp` copies the bundled
    `SampleAssets/` next to `QuickLookProtein.Settings.exe` in
    `%LocalAppData%\QuickLookProtein\Settings\` so the preview
    tiles work even when Setup.exe's staging dir gets cleaned up.

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
