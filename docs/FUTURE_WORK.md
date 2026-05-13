# Future work

This document tracks features that were scoped but deferred from the
mol2 / 3Dmol-features PR. Each item below requires adding new Xcode
targets, which is best done through the Xcode UI (right-click project →
*Add Target…*) rather than by hand-editing `project.pbxproj`.

## Phase 5 — new Quick Look entry points

### 5a. Thumbnail extension (`QLThumbnailProvider`)

Currently `.pdb`, `.cif`, etc. all share a generic Finder icon. A
thumbnail extension generates a per-file PNG that Finder uses in
Cover Flow, Gallery view, and large-icon mode.

**Steps:**

1. *Xcode → File → New → Target… → Thumbnail Extension* (macOS).
2. Bundle ID: `com.jethrohemmann.QuickLookProtein.Thumbnail`.
3. The generated `ThumbnailProvider.swift` should:
   - Build a headless `WKWebView` sized to `request.maximumSize`.
   - Load the shared `3Dmol_viewer.html` with `ROTATION_SPEED=0`,
     `SHOW_INFO=false`, transparent background.
   - In the `decidePolicyFor` / `didFinish` callback, wait for the
     WebGL canvas to settle (roughly 800 ms — 3Dmol renders async)
     then call `takeSnapshot(with:completionHandler:)`.
   - Pass the resulting `NSImage`/`CGImage` to `QLThumbnailReply`.
4. Reuse `prepare3DmolHTML` from `Shared/` — add the existing
   `Shared/` folder to the new target's *Compile Sources* phase.
5. List the same UTIs in the new target's `Info.plist` under
   `QLSupportedContentTypes`.

**Gotcha:** `WKWebView.takeSnapshot` returns blank if the view isn't
in a window. Use the workaround of attaching the web view to a
hidden `NSWindow` (off-screen frame) before snapshotting.

### 5b. Spotlight metadata importer (`.mdimporter`)

Lets Spotlight index PDB headers (TITLE, RESOLUTION, organism,
EXPDTA, etc.) so the user can search `kind:pdb resolution:<2`.

**Steps:**

1. *Xcode → File → New → Target… → Spotlight Importer*.
2. Parse the first ~50 lines of the PDB file in `GetMetadataForFile`
   (the `kMDItemTitle`, `kMDItemKeywords`, `kMDItemDescription` keys
   map naturally to PDB `TITLE`, `KEYWDS`, `COMPND`).
3. For CIF files, parse `_struct.title` and `_cell.length_*`.

## Phase 6 — main-app polish (low priority)

- Per-format default *color scheme* (not just style)
- Drag-and-drop a file into the main app to preview without invoking
  Quick Look (useful for testing settings)
- "Open in main app" button inside the Quick Look preview that hands
  off to the main app via URL scheme for a larger interactive view
- Periodic check for upstream 3Dmol.js updates (the bundled copy is
  pinned)

## Signing / App Group

The App Group identifier `W3SKSV7VPT.group.com.jethrohemmann.QuickLookProtein`
is hard-coded in `Settings.swift` and in the entitlements files. To
build under a different developer account, search-and-replace
`W3SKSV7VPT` with your own team ID in:

- `Xcode/Shared/Settings.swift`
- `Xcode/QuickLookProtein/QuickLookProtein.entitlements`
- `Xcode/QLExtension/QLExtension.entitlements`

…and update *Signing & Capabilities → App Groups* for both targets
in Xcode.
