# Changelog

All notable changes to QuickLookProtein are recorded here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com); this project does not strictly
adhere to SemVer because version numbers are driven by upstream releases.

## [1.7.91] — 2026-05-20

### 🍎 macOS — dedicated Diagnostics tab in the sidebar

Through v1.7.90 the diagnostic surfaces were scattered: extension log viewers + self-test under About → Software Update card, "Reset Quick Look cache" + "Quick Look not updating?" tile at the bottom of the Software Update tab. Users hitting "Quick Look isn't refreshing" had to know to look in two unrelated places.

v1.7.91 consolidates everything under a new **Diagnostics** sidebar entry (stethoscope icon, under the System group with Software Update and About):

- **Extension logs** card — Show Updater / QL preview / Thumbnail / Quick Actions log buttons + Reveal logs folder in Finder.
- **Self-test** card — Run diagnostic self-test (5-step check from v1.7.90) + Reveal app bundle, with the inline result block.
- **macOS Quick Look cache** card — Reset Quick Look cache (moved from Software Update → Maintenance).
- **Quick Look not updating?** expanding troubleshooting tile (moved from the bottom of Software Update).

Software Update tab is now strictly about updates (status hero, Check for Updates, Download from GitHub, auto-check toggle, frequency picker, the lastCheckStatus line). About tab is strictly credits + formats + version.

## [1.7.90] — 2026-05-20

### 🍎 macOS — drop the duplicate Rendering-Engine card + Mac-side diagnostic self-test

- **Removed the "RENDERING ENGINE" card** from the About panel — the same "Rendered by 3Dmol.js (Rego & Koes, 2015)" line was rendered twice (once as a Card, once as the footerCredit caption below). Kept the lower / quieter footerCredit instance.
- **New "Run diagnostic self-test" button** in About → Software Update → Extension logs. Mac analogue of the Windows thumbnail-provider self-test. Walks five checks:
  1. All four `.appex` bundles (QLExtension / QLThumbnail / QLActions / MDImporter) exist in `Contents/PlugIns/`
  2. App Group container resolves (entitlement provisioned)
  3. Sparkle install path is writable — when this fails Sparkle aborts with the generic "An error occurred while launching the installer" modal, and the path is the actionable clue
  4. Log directory is writable
  5. Sparkle's `SUPublicEDKey` is set (production key, not placeholder)
- Result is shown inline below the button (monospace, copy-able on macOS 12+) **and** appended to `updater.log` so it can be attached to a bug report.
- **New "Reveal app bundle" button** opens Finder pointed at `QuickLookProtein.app`'s parent so the user can right-click → Show Package Contents and inspect `Contents/PlugIns/` for entitlements/signature without dropping to the terminal.

## [1.7.89] — 2026-05-20

### 🪟 Windows — fix "Could not render molecule: ArgumentException" on large PDBs

`WebView.CoreWebView2.NavigateToString(html)` is capped at ~2 MB of content. Large PDBs (e.g. a fully-assembled ribosome with hundreds of thousands of atoms) inlined into the viewer template blow past the limit and crash with `ArgumentException: Value does not fall within the expected range` — the QL-Win preview window then shows the canned "Could not render molecule" error page instead of the structure.

v1.7.89 sidesteps the limit: the rendered HTML is written to a per-load temp file under `%LocalAppData%\QuickLookProtein\preview\preview-<guid>.html`, mapped to a new virtual host `https://quicklookprotein-preview.local/`, and navigated to via `Navigate(...)`. No content-size limit on the file path. The previous load's temp file is deleted on the next load (and on `Dispose`) so the dir doesn't grow one file per Space-bar press.

### 🪟 Windows — detect Microsoft Store QuickLook to avoid double-install

A user reported two `QuickLook-4.5.0.exe` processes running simultaneously after a Setup.exe install — one suspended (the Store version's app container), one running (our GitHub-bundled install). `Test-QuickLookInstalled` was only checking the legacy `%LocalAppData%\Programs\QuickLook` / Program Files paths; the Microsoft Store version lives under `%ProgramFiles%\WindowsApps` and was missed.

v1.7.89 adds `Test-StoreQuickLookInstalled` (calls `Get-AppxPackage -Name "*QuickLook*"`); when the Store version is present, install.ps1 skips `Install-QuickLookHost` entirely. The Store path is now recommended in the README + `docs/INSTALL.md` as the primary install route — it's signed by Microsoft, auto-updates, and runs in a sandbox.

### 📄 README simplified; details moved to docs/

The README grew to nearly 400 lines of version-stamped paragraphs and per-feature prose. v1.7.89 trims it to a tight intro + install + features matrix + troubleshooting pointer, with the long-form content moved to:
- [`docs/INSTALL.md`](docs/INSTALL.md) — every install path with the implementation notes
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — symptom → log → fix table for both OSes
- [`CHANGELOG.md`](CHANGELOG.md) (existing) — version history

## [1.7.88] — 2026-05-20

### 🪟 Windows — race fix on Quick Look fast-advance

Plugin log captured:
```
System.ObjectDisposedException: Cannot access a disposed object.
Object name: 'WebView'.
  at Microsoft.Web.WebView2.Wpf.WebView2Base.VerifyNotDisposed()
  at QuickLookProtein.Plugin.MoleculePanel.EnsureWebViewReadyAsync
  at QuickLookProtein.Plugin.MoleculePanel.LoadFile
```

QL-Win disposes the `IViewer` (and therefore `MoleculePanel`) the instant the user advances to the next file or closes the popover. If `LoadFile` was still awaiting `Task.Run(File.ReadAllText)` or `CoreWebView2Environment.CreateAsync`, the continuation would resume after Dispose ran and touch `WebView.CoreWebView2` — boom, `ObjectDisposedException` into the dispatcher's unhandled-exception handler.

v1.7.88 fixes this:
- New `_disposed` flag on `MoleculePanel`, set first in `Dispose()` before `WebView?.Dispose()`.
- `EnsureWebViewReadyAsync` re-checks `_disposed` after every `await` and throws `ObjectDisposedException` instead of letting the next line dereference a dead WebView.
- `LoadFile` catches `ObjectDisposedException` specifically and logs it as INFO ("cancelled (WebView disposed)") rather than ERR — that's the correct outcome for fast-advance, not a real failure.
- The error-render fallback also short-circuits when `_disposed` so a slow render failure doesn't itself trigger a second ObjectDisposedException trying to display the first one.

### 🪟 Windows — README: "thumbnails in Details view" is expected

Added a section explaining Windows shell behaviour: `IThumbnailProvider` is only invoked for Icon / Tile / Gallery / Content views; Details / List / Small-icon use `IExtractIcon` (which we don't implement). Users seeing white icons in Details view should switch view modes — it's not a bug, just how Explorer's column renderer works.

## [1.7.87] — 2026-05-20

### 🪟 Windows — readable + scrollable release notes in the updater card

Two paper cuts in the "Update available" panel surfaced when v1.7.86 was offered to a 1.7.84 install:

- **Notes are now scrollable.** The `UpdateNotesLabel` was a plain `TextBlock` with `MaxHeight=220` — content past 220 px clipped silently, hiding the Option B / Homebrew install paths + everything else below the fold. v1.7.87 wraps it in a `ScrollViewer` (`MaxHeight=260`, `VerticalScrollBarVisibility=Auto`); the new Fluent-thin scrollbar template kicks in automatically.
- **HTML tags stripped instead of leaking through.** GitHub release bodies routinely contain `<kbd>Space</kbd>`, `<details>`, `<summary>` and friends that GitHub's web UI renders client-side. WPF's `TextBlock` has no HTML parser, so the raw tags were rendering literally ("press `<kbd>Space</kbd>` in Finder"). `TruncateMarkdown` now:
  - Converts `<kbd>X</kbd>` → `[X]` (preserves the keyboard-key meaning)
  - Converts `<summary>X</summary>` → `▸ X` (preserves the disclosure-row meaning)
  - Strips every other `<…>` tag, keeps inner text
  - Decodes the common HTML entities (`&nbsp;`, `&amp;`, `&lt;`, `&gt;`, `&quot;`)
  - Rewrites Markdown links `[text](url)` → `text (url)` so the URL stays visible after tag-strip
- **Truncate limit 500 → 4000 chars** so the typical multi-paragraph release entry fits without trailing ellipsis.

## [1.7.86] — 2026-05-20

### 🪟 Windows — make broken-registration recovery a single click

v1.7.85 added the Repair button under About → Diagnostics, but users hitting white thumbnails were arriving at the Thumbnails tab first, picking "Auto" or "Cartoon" from a dropdown, seeing nothing happen, and assuming the dropdown was broken (it wasn't — the writes saved, but the DLL still wasn't loaded so the visible result was identical). v1.7.86 makes the broken state obvious *on the same tab the user lands on* and the fix one click away:

- **Registration-status banner** at the top of the Thumbnails tab. Hidden when the CLSID's `InProcServer32` is present in HKCU; visible (warning-yellow, accent-stroked) with a "Repair now" button when it's missing. Checked on window load and re-evaluated after every successful repair. Stops users from fiddling with a dropdown that can't affect anything until registration is fixed.
- **"Repair now" inline in the self-test dialog.** When **Test thumbnail provider** finds step 1 or step 2 MISSING, the result MessageBox is now Yes/No: Yes runs `RepairThumbnailRegistration` and re-runs the test so the user sees the post-repair OK state before closing. Cuts the recovery flow from four clicks (Test → see error → close → find Repair button → click → re-test) to two (Test → Yes).

## [1.7.85] — 2026-05-20

### 🪟 Windows — "Repair thumbnail registration" button

v1.7.83's self-test surfaced a partial-registration failure mode that real users are hitting on Win11: the per-extension shell-handler keys are present (step 1 OK) but the CLSID's `InProcServer32` entry is missing (step 2 MISSING). Most likely cause: an old QuickLookProtein uninstall, a system-cleaner tool, or a security product wiped only the CLSID node and left the per-extension breadcrumbs pointing at a dead end.

v1.7.85 lets users fix this in one click from Settings → About → Diagnostics → **"Repair thumbnail registration"**. The button rewrites the same HKCU keys `install.ps1`'s `Register-ThumbnailHandler` writes on first install — CLSID + `InProcServer32` (`mscoree.dll` bridge, `Assembly`, `Class`, `CodeBase`, `RuntimeVersion`), plus the per-extension `ShellEx\{IID}` entries for all 16 supported extensions, then broadcasts `SHChangeNotify(SHCNE_ASSOCCHANGED)` so Explorer re-walks the extension-to-CLSID map without an explorer.exe restart.

DLL discovery probes both QL-Win 4.x (`%AppData%\pooi.moe\QuickLook\QuickLook.Plugin\QuickLookProtein\`) and legacy 3.x (`%LocalAppData%\QuickLook\plugins\QuickLookProtein\`) plugin paths; if the DLL isn't in either, the button surfaces "the DLL itself is missing — re-run Setup.exe" rather than writing dead registry entries.

After repairing, re-run **"Test thumbnail provider"** — all four steps should report OK. Switch a folder of `.pdb` / `.cif` / `.sdf` files to Icon view and the thumbnails should redraw within a second or two.

## [1.7.84] — 2026-05-20

### 🍎 macOS — diagnostic log viewer for every extension

The Updater already wrote a file log since v1.7.80, but the three Quick Look extensions (preview, thumbnail, Quick Actions) only emitted `os_log` against per-extension subsystems — only retrievable via `log show` or Console.app, both of which a sandboxed Settings UI cannot reach (sandbox blocks `/var/db/diagnostics`). When a preview rendered as a blank document or a thumbnail came back generic, there was no way for a user to ship a useful bug report.

v1.7.84 adds a file-based diagnostic logger to each extension and a viewer in the main app:

- **`DiagLog` helper** in `PreviewViewController.swift`, `ThumbnailProvider.swift`, and `ActionRequestHandler.swift`. Each writes timestamped lines to its own log under  
  `~/Library/Group Containers/<group>/Library/Logs/QuickLookProtein/`  
  (sandbox-local `~/Library/Logs/QuickLookProtein/` fallback when the App Group container isn't provisioned). Files: `qlpreview.log`, `qlthumbnail.log`, `qlactions.log`. 2 MB cap with truncate-and-restart so no file grows unbounded.
- **Entry + catch instrumentation** at the key points: `preparePreviewOfFile`, `provideThumbnail`, `beginRequest`, the merged-PDB writer, the share-temp-PNG writer, the USDZ exporter. Every error path now leaves a forensic trail.
- **"Extension logs" section in About → Software Update** with one button per component (Updater · Quick Look preview · Thumbnail · Quick Actions). Tapping opens a `LogViewerSheet` that reads the corresponding file, defaults to the last 200 lines (toggle for full file), and exposes Reveal-in-Finder / Refresh / Copy / Save buttons. Identical UX across all four targets.
- **"Reveal logs folder in Finder"** button as a fast escape hatch — jumps straight to the App Group `Library/Logs/QuickLookProtein` directory so users can grab the whole folder for a bug report in one drag.

We deliberately do *not* shell out to `/usr/bin/log show` from the sandboxed main app — it would silently return empty because the sandbox blocks `/var/db/diagnostics` access. File-based logging via the shared App Group works inside the sandbox without extra entitlements.

## [1.7.83] — 2026-05-20

### 🪟 Windows — real PNG logo + thumbnail self-test

Two follow-ups from the v1.7.82 round of fixes:

- **Sidebar logo finally renders crisp.** v1.7.82's "BitmapImage with `DecodePixelWidth=256`" trick didn't actually upscale the icon — `DecodePixelWidth` is a no-op on multi-frame ICOs, and WPF's `IconBitmapDecoder` returns `Frames[0]` (the 16-px entry) regardless. v1.7.83 ships `Resources\AppLogo-256.png` (the 256-px frame extracted from the ICO at build prep time) and references that directly. The ICO still drives the EXE icon + taskbar + window title-bar entries where the OS picks the right frame itself.
- **Thumbnail provider self-test button in About → Diagnostics.** v1.7.82's thumbnail logger only fires when Explorer actually loads the DLL — if registration is broken or Explorer rejects the load, the log stays empty (which is exactly what users reported). The new **"Test thumbnail provider"** button walks the chain explicitly:
  1. Reads `HKCU\…\Classes\.pdb\ShellEx\{E357…E96}` (per-extension shell handler)
  2. Reads `HKCU\…\Classes\CLSID\{B7E4…7A1}\InProcServer32` (CLSID + CodeBase)
  3. `Assembly.LoadFrom(CodeBase)` (managed assembly loads at all)
  4. `Activator.CreateInstance(Type.GetTypeFromCLSID(...))` (COM activates — the exact path Explorer uses)
  
  Result of each step is appended to `thumbnail.log` and shown in a MessageBox; the user gets actionable text ("step 1 MISSING → re-run Setup.exe", "step 4 ERROR: CLR conflict → ship the log") rather than another silent failure.

## [1.7.82] — 2026-05-20

### 🪟 Windows — Settings polish + the *real* version-string bug

v1.7.81 had a hidden bug that turned every "Check for updates" click into a guaranteed 403: the Settings exe reported its own version as `1.0.0.0`, the updater compared that against GitHub's tagged release, decided "yes, new release exists", and beat the anonymous /releases/latest endpoint until it tripped the 60-req/IP/hour limit. v1.7.82 fixes the root cause and several smaller UI issues spotted in the same screenshot.

- **Version string now reads `FileVersion`, not `AssemblyVersion`.** The csproj intentionally pins `AssemblyVersion=1.0.0.0` so WPF binding redirects stay stable across marketing bumps; only `FileVersion` / `InformationalVersion` carry the real version. `UpdateChecker.CurrentVersion` and `MainWindow.SetVersionLabel` now route through `FileVersionInfo.GetVersionInfo(Assembly.GetExecutingAssembly().Location)` so the sidebar, About card, and "Installed version:" line all show the actual installed version (1.7.82 in this build).
- **Specific 403 / rate-limit handling.** `CheckAsync` now reads the status code + `X-RateLimit-Reset` header and throws a typed `RateLimitedException`. The Settings UI catches that specifically and surfaces *"GitHub's anonymous API limit (60 checks/hour) is exhausted on your IP. Try again after 14:23, or click 'Open release page' to see the latest version manually."* instead of the generic *Couldn't reach GitHub* message. The `Open release page` button is also revealed even when there's no `_pendingUpdate`, so users always have a manual escape.
- **Sidebar logo at 256-px decode.** The `.ico` holds 16/32/48/64/128/256 frames; WPF's default `Image.Source="pack://…/AppIcon.ico"` picks the first frame (16 px) and upscales — hence the pixelated look. v1.7.82 uses an explicit `BitmapImage UriSource=… DecodePixelWidth="256"` so WPF selects the 256-px PNG-encoded frame and downsamples cleanly to 56.
- **Default window size 820 × 660** (was 980 × 780). Matches the compact Mac System-Settings footprint the user showed in the reference; min-size also dropped to 720 × 580.
- **Win11-style ScrollBar template.** The default WPF chrome (arrow buttons, square thumb, chunky track) was replaced with a Fluent-style 10-px thin track + rounded thumb that ramps opacity 0.55 → 0.85 → 1.0 on hover and drag. Applied as the implicit `ScrollBar` style so every scrollable surface in the window picks it up.
- **WebView2 / footer overlap.** The Live Preview's WebView2 (HWND-hosted) was rendering on top of the WPF footer due to the long-standing WPF airspace problem. v1.7.82 drops the WebView2 height from 320 → 260 px, sets `ClipToBounds="True"` on its containing `Border`, and adds 24 px of bottom padding to the ScrollViewer so even during scroll the live-preview tile stays well clear of the Close-button bar.
- **Thumbnail provider gets the same diagnostic logger.** New `LogPath` → `%LocalAppData%\QuickLookProtein\thumbnail.log` (1 MB rotation). `Initialize` logs bytes-read + sniffed extension; `GetThumbnail` logs requested size, parsed atom count, the rendered HBITMAP dimensions, and any caught exception with full type + stack. New **"Open thumbnail log"** button in About → Diagnostics so when thumbnails are "still white after refresh" the user can see which step failed (DLL not loaded → empty file; parse error → WARN line; render error → ERR + stack).

## [1.7.81] — 2026-05-20

### 🍎 macOS — System-following / Light / Dark theme picker

New **App appearance** section at the top of Appearance → settings: `System` (default — follows macOS Appearance setting), `Light`, `Dark`. Implemented via SwiftUI's `.preferredColorScheme()` on `ContentView` — `nil` for System (the existing "follow the user's macOS-wide setting" behaviour the app has always had), `.light` / `.dark` to pin the window regardless of the system setting. Stored as `Settings.AppearanceMode` in the App-Group `UserDefaults`, so the choice survives relaunch and is consistent across the Quick Look extension's preview process. SwiftUI already updates the entire view tree on a `.preferredColorScheme` change, so flipping the picker is instant.

### 🪟 Windows — Settings app redesign (sidebar nav, system-following theme, Mica)

The Windows Settings app shipped through v1.7.80 as a single vertical-scroll wall of dark cards. v1.7.81 rebuilds it from the chrome down to feel native on Windows 11 and match the macOS app's structure.

**Sidebar nav** — Mac-System-Settings layout. The old single-scroll page is now split into nine tabs (General · File Formats · Appearance · Rendering · Toolbar · Info Overlay · Thumbnails · Software Update · About) with a 220 px left-rail `ListBox` driving visibility. Adding a new section is one XAML entry + one line in `AllTabs()`.

**System-following light / dark theme.** Every theme-sensitive brush is a `DynamicResource`; `ApplyTheme()` mutates the `SolidColorBrush.Color` of each entry in place when the system theme flips, so the whole window repaints without us walking the visual tree. Theme is read from `HKCU\…\Themes\Personalize\AppsUseLightTheme` on load and on every `SystemEvents.UserPreferenceChanged` broadcast (the WM_SETTINGCHANGE that fires when the user toggles Settings → Personalisation → Colours). Colour values follow Windows 11's Fluent palette so the window blends with native chrome.

**Mica backdrop on Windows 11.** `ApplySystemBackdrop()` calls `DwmSetWindowAttribute` with `DWMWA_SYSTEMBACKDROP_TYPE = 2` (Mica) on Win11 22H2+, falling back to the pre-22H2 `DWMWA_MICA_EFFECT = 1029` flag on 21H2. The `AppBg` brush is transparent so the DWM-painted backdrop shows through the title bar + any padding; sidebar and content paint their own surfaces. Dark title bar enabled via `DWMWA_USE_IMMERSIVE_DARK_MODE = 20` so the caption strip matches the rest of the window in dark mode. Win10 silently uses the AppBg solid colour (Mica is a no-op there).

**Higher-quality logo.** The sidebar logo now renders at 56×56 with `RenderOptions.BitmapScalingMode="HighQuality"` and `UseLayoutRounding="True"`. The `.ico` has 256 px frames; WPF picks the nearest and downsamples cleanly instead of stretching the 16/32 px frames it grabbed by default.

**Better Fluent controls.** Win11 4 px-radius pill buttons; new accent-filled CheckBox template (rounded square + white tick) replacing WPF's chunky default; Slider with `IsMoveToPointEnabled="False"` so a stray click on the track no longer jumps the thumb to the cursor.

**Slider mouse-wheel suppression.** Mouse-wheel-over-slider was the source of the "sensitivity too high" complaint — a single wheel notch moved the preview-window-size slider 80 px because `SmallChange × Δ/120` ≈ 80 on the wide 240–2400 range. `ConfigureSliders()` now eats `PreviewMouseWheel` on both sliders entirely; users can still drag the thumb, type into the text box, or click the Compact / Default / Large presets.

### 🪟 Windows — per-format thumbnail style picker

New **Thumbnails** tab matches the Mac app's per-format style settings:

- `ThumbnailStyle` enum added to `Shared\SettingsStore.cs` with Auto / Cartoon / CPK / Sphere / Stick values.
- `ThumbnailProvider.GetThumbnail` now reads `HKCU\…\Settings\ThumbStyle<EXT>` via the new `SettingsStore.GetThumbStyle(ext)` helper. **Auto** preserves the original heuristic (cartoon ribbon for files with ≥3 CA atoms, CPK otherwise) so existing users see no behaviour change on first run.
- Twelve per-format ComboBoxes (PDB · CIF · SDF · MOL · MOL2 · XYZ · GRO · CUBE · PQR · VASP · CDJSON · MMTF) plus a "Reset to Auto" button and a "Refresh thumbnails now" shortcut.
- The `Shared\SettingsStore.cs` file is now `Compile`-linked into `QuickLookProtein.Thumbnail.csproj` so the provider can read the same registry hive the Settings app writes.

Sphere maps to `CpkRenderer` (CPK is element-coloured spheres); Stick currently falls back to CPK until a dedicated stick-radius renderer lands.

## [1.7.80] — 2026-05-20

### 🐞 Both OSes — diagnostic logging for the updater path

Multiple users (and the maintainer) have hit silent or generic-message failures during in-app updates — Mac shows "An error occurred while launching the installer" with no further detail; Windows surfaces a `MessageBox` for the HTTP layer but swallowed everything else. The actual `NSError` / `Exception` was never written anywhere a user (or bug report) could retrieve, so each failure became a guessing game.

v1.7.80 wires both updaters into an on-disk log and surfaces the underlying error in the Settings UI itself. Nothing about the update flow changes for the happy path; this is purely defensive instrumentation.

**🍎 macOS — `Updater.swift`**

- `Updater` now implements `SPUUpdaterDelegate`'s `updater(_:didAbortWithError:)`. When Sparkle bails (e.g. installer-launch failures, signature mismatches, host-version comparison aborts) the underlying `NSError` is unwrapped and pretty-printed: domain, code, `localizedDescription`, `localizedFailureReason`, `localizedRecoverySuggestion`, plus any `NSUnderlyingError` chain.
- New `@Published var lastInstallError: String?` flows that error into `ContentView`'s **Software Update** card — orange-tinted, monospace, `.textSelection(.enabled)` on macOS 12+ so users can copy the text into a bug report.
- All updater state transitions (`check started / found update / abort / install will-begin / install did-finish`) write timestamped lines to a rolling log at  
  `~/Library/Group Containers/<group>/Library/Logs/QuickLookProtein/updater.log`  
  (falls back to `~/Library/Logs/QuickLookProtein/updater.log` when the App Group container can't be resolved, e.g. on first-launch sandboxing).
- New **"Open update log"** SecondaryPillButton opens the file in the user's default text viewer (Console / TextEdit), falling back to a Finder reveal if `NSWorkspace.open` fails.

**🪟 Windows — `UpdateChecker.cs`**

- New `public static string LogPath` → `%LocalAppData%\QuickLookProtein\update.log`, with 1 MB rotation (`update.log.1` keeps the previous tail) so the file never grows unbounded across years of update checks.
- `CheckAsync` now logs the start of the check, the GitHub API response size, missing-tag / missing-asset warnings, version-parse failures, and every caught exception (via `LogException`, which writes `HResult`, message, full type name and the stack trace).
- `DownloadAndInstallAsync` logs the start of the download, the `Content-Length` (or `unknown`), copied bytes on completion, the `Setup.exe` launch attempt, and any HTTP non-2xx response. Each retry/failure path is wrapped in `try / LogException` so the next person who hits a silent failure has the actual exception in hand.
- New **"Open update log"** button next to "Open release page" in the Software Update card. If the file doesn't exist yet (no check has run on this machine) the handler writes an explanatory header so Notepad doesn't pop a "do you want to create this file?" prompt.

**Why now**: the maintainer hit "An error occurred while launching the installer" three times during this release cycle (1.7.65→1.7.66, 1.7.65→1.7.68, 1.7.78→1.7.79) on a machine running Parallels + AlDente, and `log show --predicate 'subsystem == "org.sparkle-project.Sparkle"'` returned **zero** entries each time — Sparkle aborts synchronously before it logs anything. The delegate hook plus the file logger collectively guarantee that the next time it happens, the exact failure reason is captured both in-app and on disk.

## [1.7.79] — 2026-05-20

### 🪟 Windows — fix silent-install failure on upgrade-over-running-QL-Win

User reported `Setup.exe` ran but **nothing happened** afterward — Settings app didn't appear in Start Menu or Add/Remove Programs, and `%TEMP%\QuickLookProtein-install.log` revealed:

```
==> Installing plugin
Remove-Item : Cannot remove item …\WebView2Loader.dll: Access to the path 'WebView2Loader.dll' is denied.
At …\install.ps1:229 char:29
+         if (Test-Path $d) { Remove-Item -Recurse -Force $d }
```

**Root cause**: `Plugin.cs`'s static cctor (1.7.71+) calls `LoadLibraryW("WebView2Loader.dll")` to pin the bitness-matched native loader into QL-Win's process. That leaves an open handle on the DLL. When the user re-ran `Setup.exe` to upgrade (the common case once auto-update is wired up), `install.ps1`'s wipe-then-reinstall step couldn't delete the locked DLL → `Remove-Item` threw → `$ErrorActionPreference = "Stop"` exited the script immediately → **every subsequent step was skipped**: Settings.exe never copied, Add/Remove Programs entry never written, Start Menu shortcut never created, app-launch step never fired. Hence "nothing happens".

**Fix**: `install.ps1`'s `Install-Plugin` now stops the running QuickLook process *before* the wipe, then `Restart-QuickLookHost` brings it back at the end of the script (existing behaviour). Uses the same `Try-StopQuickLook` graceful-then-firm sequence the script already had for `Restart-QuickLookHost`, plus a 750 ms breather so the kernel finishes releasing DLL handles before `Remove-Item` retries.

Every install path is now upgrade-safe regardless of QL-Win running state. Users who hit the silent-install bug on 1.7.66 → 1.7.78 just need to grab v1.7.79's Setup.exe; no manual cleanup required.

### 🍎 macOS — UI polish

- **"Open at login" toggle moved from Appearance to General** → Quick Look card, sitting next to the master "Enable QuickLookProtein2" toggle. Belongs in General since both control the app's baseline behaviour, not viewer appearance. (User feedback: "this button in mac should be under general tab".)
- **Hover tooltips on the About → Supported Formats grid** so users hovering a truncated entry (e.g. "Crystallographic..." in a narrow four-column layout) see the unabridged name + the file extensions. Tooltip wires through a per-extension lookup so the hover text is always the canonical spelling regardless of the visible truncation.

## [1.7.78] — 2026-05-20

### 🔧 Hotfix for v1.7.77's partial-release

v1.7.77's tag shipped only the macOS DMG; the Windows side of the release pipeline failed during `Build Settings WPF app` because `UpdateChecker.cs` used two features the net472 SDK doesn't auto-provide:

- `using System.Net.Http;` — `HttpClient` is in the net472 reference assemblies but isn't auto-referenced in SDK-style csproj. **Fixed**: explicit `<Reference Include="System.Net.Http" />` in `QuickLookProtein.Settings.csproj`.
- `public string TagName { get; init; }` — C# 9's init-only setters require `System.Runtime.CompilerServices.IsExternalInit`, which ships in .NET 5+ but not Framework. **Fixed**: new `IsExternalInit.cs` polyfill (the [officially-blessed Roslyn pattern for downlevel targets](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/proposals/csharp-9.0/init)).

### 🛡 `ci-validate` now mirrors release.yml's build flags

User flagged the actual gap: `ci-validate.yml` was building with `dotnet build -c Release` but the release workflow builds with `/p:Version=$ver /p:FileVersion=$ver /p:InformationalVersion=$ver`. A code change that compiled fine without the version cascade but failed with it (exactly what 1.7.77 hit) wouldn't have been caught by CI. **Fixed**: `ci-validate.yml`'s plugin + Settings build steps now pass `/p:Version=0.0.0-ci /p:FileVersion=0.0.0 /p:InformationalVersion=0.0.0-ci` so the version-stamped code path is exercised on every push to feature/**.

The release workflow's atomic-publish gate (don't create the GitHub release until both Mac and Windows builds succeed) is queued for a separate follow-up — it requires restructuring release.yml's job graph and is larger than this hotfix should carry.

## [1.7.77] — 2026-05-20

### 🪟 Windows — in-process auto-updater (finally)

The Mac has had Sparkle since the rebrand; Windows has been re-downloading `Setup.exe` manually for every release. Fixed.

- **New `UpdateChecker.cs`** in the Settings WPF app — managed-only, ~250 lines, no native dependencies (deliberately not pulling in WinSparkle's 1.6 MB native DLL when our flow is just "GET releases/latest → compare versions → run Setup.exe"). Hits `https://api.github.com/repos/ArioMoniri/QuickLookProtein/releases/latest`, parses `tag_name` + `html_url` + the assets array, finds `QuickLookProtein-Setup.exe`, and compares the version against the running Settings.exe's `FileVersion`.
- **New "Software Update" card** in Settings (right above Startup). Shows the installed version on load. Three buttons: **Check for updates** (manual, always works), **Install update** (downloads + runs `Setup.exe` + quits Settings so Setup.exe can replace files without an in-use lock), **Open release page** (browser jump to the GitHub release).
- **Opt-in auto-check at launch** via the "Check for updates automatically when this window opens" checkbox. Off by default for the first release of this feature so existing users aren't surprised by a network call they didn't ask for; on means a fire-and-forget GitHub round-trip every time Settings opens (the UI is never blocked).
- **Settings.exe FileVersion now stamped** by the release workflow (`dotnet build /p:Version=$ver /p:FileVersion=$ver /p:InformationalVersion=$ver`) — same pattern the Plugin DLL has used since 1.7.70. Local dev builds default to `0.0.0` so a stray dev EXE is identifiable.
- **Force TLS 1.2** on the HttpClient before hitting GitHub — .NET Framework 4.7.2 sometimes defaults to TLS 1.0 which GitHub's API has rejected since 2018.
- **No upgrade required** to switch over: the next release a 1.7.77+ user installs surfaces the Update card automatically; the "Check for updates" button works the moment the Settings window opens.

Update flow on the user's machine:
1. Settings opens → checks GitHub (if auto-check on) or user clicks **Check for updates**.
2. If a newer release is published, the status line reads `Update available: vX.Y.Z (you have …)`, the release notes excerpt populates below it (first 500 chars of the GitHub release body, with markdown stripped to plain-ish text), and **Install update** appears.
3. User clicks **Install update** → progress bar in the status line as bytes stream to `%TEMP%\QuickLookProtein-Setup-vX.Y.Z.exe` → Setup.exe launches → Settings.exe shuts down so Setup.exe can replace it.
4. Setup.exe handles the plugin DLL install at the QL-Win 4.x path (since 1.7.73), the auto-thumbnail-refresh broadcast (since 1.7.76), and re-launches the Settings app at the end (since 1.7.76).

README's Settings-app section gains a "Software Update on Windows" subsection alongside the Mac Sparkle one so users discover the feature.

## [1.7.76] — 2026-05-20

### 🪟 Windows — first-run experience and thumbnail cache refresh

User reported `.pdb` files showed blank/white thumbnails in Icon view after install, even though the diagnostic showed our `IThumbnailProvider` was correctly registered under `HKCU\Software\Classes\.pdb\ShellEx`. Cause: `install.ps1` cleared the icon cache (`ie4uinit -ClearIconCache`) but didn't tell Explorer that file *associations* had changed, so it kept serving its in-memory CLSID->handler mapping without re-querying our new entry.

- **`install.ps1` now broadcasts `SHChangeNotify(SHCNE_ASSOCCHANGED)`** after the thumbnail-handler registration. Explorer re-reads associations and re-asks our handler for visible folders without any process kill. Same broadcast a well-behaved Inno Setup script triggers via the `ChangesAssociations` directive.
- **New "Refresh thumbnails" button** in Settings → Diagnostics. Runs the same broadcast + ClearIconCache from the user's session for cases where the install-time broadcast didn't propagate (RDP sessions, fast-user-switch scenarios). Shift-click does a nuclear-option `explorer.exe` kill (the shell auto-respawns) for the rare cases where SHChangeNotify isn't enough.

### 🪟 Windows — launch-at-startup

- **Fixed code-comment mismatch in `install.ps1`**: the comment block claimed we passed `/TASKS=startup` to QL-Win's Inno Setup installer, but the actual `-ArgumentList` didn't include it. Users were finding QL-Win disabled after every reboot and had to manually re-enable startup from QL-Win's tray menu. Added the missing arg.
- **New "Startup" card in the Settings app** with a "Launch QuickLook at sign-in" checkbox. Reads + writes `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\QuickLook` (same key QL-Win's tray menu uses) so flipping it here flips QL-Win's view of the same setting. The value points at the installed `QuickLook.exe` (Local/Programs/QuickLook, Program Files, or Program Files (x86); whichever exists).

### 🪟 Windows — Settings app launches after every install (not just first)

- Previously gated on `-not (Test-Path Settings.exe)` so only the FIRST install opened the Settings window. Upgrades stayed silent, which left users wondering whether the upgrade had finished. Now the Settings window opens after every install run unless `QLP_SKIP_LAUNCH=1` is set (for headless CI installs into throwaway profiles). This also surfaces the new Startup / Preview-size / Refresh-thumbnails controls to existing users without them needing to dig through the Start Menu.

### 🍎 macOS — Open at login toggle

- **New `Xcode/QuickLookProtein/LoginItem.swift`** wraps `SMAppService.mainApp` (macOS 13+) so the Settings UI can flip "launch QuickLookProtein2 at sign-in" without diving into System Settings. The toggle in Settings → Appearance reads the runtime state via `SMAppService.mainApp.status` so it stays in sync if the user flips it elsewhere.
- **macOS 11/12 fallback**: those versions don't expose a sandboxed programmatic toggle; the Settings row instead shows an "Open Login Items…" button that deep-links into `System Settings → General → Login Items` so the user can add the app there with one click. The deep-link URL has been stable since Big Sur even though the pane moved between "System Preferences" and "System Settings" in macOS 13.

### Both — README

The Settings section's matrix now includes Launch-at-startup behaviour per OS alongside Preview-size. Diagnostics section gains a "white thumbnails after install" entry pointing at the new Refresh button.

## [1.7.75] — 2026-05-20

### 🪟 + 🍎 User-tunable Quick Look preview window size

A user reported the Windows QL preview was still too large at 720×420 and asked for a way to adjust the initial popover size. Done — and mirrored on the Mac side so the same setting works on both platforms (with the OS-imposed caveats noted below).

- **New shared setting `PreviewWidth` / `PreviewHeight`** (registry on Windows under `HKCU\Software\QuickLookProtein\Settings`, `NSUserDefaults` on macOS under `previewWidth` / `previewHeight`). Default **560 × 420** — the smallest size that comfortably fits atom labels at default zoom while still feeling like a Quick Look popover.
- **🪟 Windows Settings → Preview window card** with sliders + numeric text boxes + one-click presets (Compact 480×360 / Default 560×420 / Large 960×720). `Plugin.Prepare` reads the live values from the registry on every Space-bar tap, so changes apply with no QL-Win restart. QL-Win still lets the user drag-resize the popover after it appears; the slider in Settings controls the *initial* size only.
- **🍎 macOS Settings → Appearance → Preview size** with W × H text fields and a "Default" button. `PreviewViewController.loadView` sets `preferredContentSize` from this on the first preview of each file type. Apple's Quick Look only honours that hint the first time a UTI is previewed; after that, Finder persists the user's last drag-resize per-UTI and ignores the setting. So adjust here on a clean install or when you want a different starting geometry for a brand-new file type.

README's "Settings app" section now carries a full preview-window-size matrix (where the control lives on each OS, what's actually persisted, and the platform-specific limits).

### Cross-cutting

No functional change to the render path. Settings store + UI plumbing on both platforms; everything else from 1.7.66 → 1.7.74 remains.

## [1.7.74] — 2026-05-20

### 🪟 Windows polish round

With the plugin discovery finally working in 1.7.73 (user-verified 3D ball-and-stick render of D16 Ideal Structure in QL-Win), four polish items:

- **Smaller default preview window** — `Plugin.Prepare` set `PreferredSize = new Size(960, 720)` since 1.7.66, which dominated 1080p screens. Dropped to **720×540** — large enough to read atom labels at default zoom, small enough to feel like a QuickLook *popover* instead of a full window. Users can still resize freely.
- **App icon for `QuickLookProtein.Settings.exe`** — built a multi-resolution `Resources/AppIcon.ico` (16/32/48/64/128/256 frames, all 32-bit RGBA) from the existing macOS PNG icon set and wired it into the csproj as both `<ApplicationIcon>` (drives Windows Explorer + Start Menu + taskbar) and `<Resource>` + `Window.Icon` (drives the WPF title-bar icon). The blank-document icon previous Setup.exes shipped is gone.
- **Visual polish on the Settings UI** — the WPF window picked up:
  - A gradient header strip with the embedded app icon to the left of the title.
  - A `SecondaryButton` style with hover + pressed + disabled states applied automatically to every plain `<Button>` via an unkeyed `Style TargetType="Button"` (replaces WPF's chunky default chrome).
  - `DropShadowEffect` on cards so the dark surface reads as layered against the slightly darker app background instead of flat grey-on-grey.
  - `PrimaryButton` gets matching hover (`#557DEA`) + pressed (`#2F58C9`) accent variants instead of a static fill.
  - Card `CornerRadius` 10 → 12 for softer Fluent-style corners.
- **Header rebrand** — Settings window header now reads **QuickLookProtein2** (was still "QuickLookProtein"). Aligns with the rest of the rebrand from 1.7.66.

No functional changes to the render path. The plugin discovery + AnyCPU + runtimes/ + AssemblyResolve + cctor hardening from 1.7.68–1.7.73 is all retained.

### Windows Explorer thumbnails — yes, registered

For anyone who asked: install.ps1 has registered an Explorer thumbnail handler for every supported extension (`.pdb` / `.cif` / `.sdf` / `.mol` / `.mol2` / `.xyz` / `.gro` / `.cube` / `.cub` / `.vasp` / `.poscar` / `.cdjson` / `.pqr`) since 1.7.13 — that hasn't changed. Switch a folder to **Icon / Tile / Gallery view** in Explorer and you'll see CPK / cartoon-ribbon thumbnails rendered by `QuickLookProtein.Thumbnail.dll`. If thumbnails don't refresh after a re-install, run `ie4uinit -ClearIconCache` (the installer does this automatically, but Explorer caches across sessions).

## [1.7.73] — 2026-05-20

### 🎯 Windows — **the actual root cause**: wrong plugin folder for QL-Win 4.x

After five increasingly desperate hotfixes (1.7.68 → 1.7.72) attacking imaginary code-load failures, the user's QL-Win-version diagnostic revealed the real bug: **`install.ps1` was installing the plugin to the wrong folder all along**. QL-Win 4.0 (released early 2025) relocated the user-plugin scan path. We were installing to the 3.x path.

| QL-Win 3.x scan path (where we installed) | QL-Win 4.x scan path (where it actually scans) |
|---|---|
| `%LocalAppData%\QuickLook\plugins\<plugin>\` | `%AppData%\pooi.moe\QuickLook\QuickLook.Plugin\<plugin>\` |

Source: `QuickLook/App.xaml.cs` defines `UserPluginPath = Path.Combine(SettingHelper.LocalDataPath, "QuickLook.Plugin\\")`, and `QuickLook.Common/Helpers/SettingHelper.cs` defines `LocalDataPath = Path.Combine(Environment.SpecialFolder.ApplicationData, "pooi.moe\\QuickLook\\")` for non-portable installs. `PluginManager.LoadPlugins` then does `Directory.GetFiles(folder, "QuickLook.Plugin.*.dll", SearchOption.AllDirectories)` against that path.

Releases 1.7.66 through 1.7.72 all landed in the 3.x folder, which QL-Win 4.5.0 simply doesn't scan. That's why **every** diagnostic showed the assembly was structurally fine (`Assembly.LoadFrom`, `GetTypes()`, `Activator.CreateInstance(Plugin)` all succeeded in standalone PowerShell) but `plugin.log` never appeared after Space-bar: QL-Win was never given the chance to load our DLL.

**Fix**: `install.ps1` now installs to **both** paths — `%AppData%\pooi.moe\QuickLook\QuickLook.Plugin\QuickLookProtein\` as the primary (QL-Win 4.x) and `%LocalAppData%\QuickLook\plugins\QuickLookProtein\` as the legacy mirror (so anyone still on QL-Win 3.x keeps working). The Setup.exe payload is unchanged; only the install destination moves. Uninstaller template updated to clean both locations.

The diagnostic + code-shape work from 1.7.68 → 1.7.72 (AssemblyResolve hook, AnyCPU, runtimes/ subtree, LoadLibraryW preload, type-decoupling, cctor sentinel) was *necessary* — it ruled out every other failure mode and pointed at the install layout as the last remaining suspect. But the *sufficient* fix is just one line: the plugin path.

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
