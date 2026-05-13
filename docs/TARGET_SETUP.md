# Adding the Phase 5 extension targets in Xcode

This PR ships the **source files** for two new app extensions but does not
include them as Xcode targets. Adding the targets through the Xcode UI is
faster and safer than hand-editing `project.pbxproj`. Each takes about a
minute.

> **Why not auto-add the targets?** `project.pbxproj` is a fragile property
> list with hand-rolled UUIDs and cross-references. A single missing field
> renders the project file unopenable. Xcode's "Add Target" assistant
> produces a known-good baseline you can then customise.

## A. Thumbnail extension (`QLThumbnail`)

Source: [`Xcode/QLThumbnail/`](../Xcode/QLThumbnail)

1. Open `Xcode/QuickLookProtein.xcodeproj`.
2. **File → New → Target…**
3. Filter "thumbnail", choose **Thumbnail Extension** under *macOS*, click **Next**.
4. Fill in:
   - Product Name: `QLThumbnail`
   - Team: *(your developer team)*
   - Bundle Identifier: `<your prefix>.QuickLookProtein.Thumbnail` (must be
     unique). Xcode auto-fills based on the parent app's bundle ID.
   - Language: Swift
   - Embed in Application: `QuickLookProtein`
5. Click **Finish**. (If Xcode asks to activate the scheme, decline — the
   host-app scheme is what you'll build.)
6. Xcode generates `ThumbnailProvider.swift` and `Info.plist` inside a
   new `QLThumbnail` folder. **Delete those generated files** (move to
   Trash) — we ship our own.
7. Drag the existing files into the new target group:
   - `Xcode/QLThumbnail/ThumbnailProvider.swift`
   - `Xcode/QLThumbnail/Info.plist`
   - `Xcode/QLThumbnail/QLThumbnail.entitlements`
   When prompted: target membership = `QLThumbnail` only (not the host app).
8. Also add the **Shared/** sources to the new target. In the file inspector
   for **each** of these files, tick the `QLThumbnail` checkbox under
   *Target Membership*:
   - `Xcode/Shared/Settings.swift`        (needed for `Settings.dataFormat`)
   - `Xcode/Shared/SharedFunctions.swift` (needed for `prepare3DmolHTML`,
     `ViewerOptions`, `oversizedFileHTML`)
   Skipping `Settings.swift` will cause an "unresolved identifier `Settings`"
   compile error.
9. Add the viewer assets as **resources** of the new target. Select
   `Shared/Assets/3Dmol_viewer.html` and `Shared/Assets/3Dmol.js` in the
   navigator → file inspector → tick `QLThumbnail` under *Target Membership*.
10. In the `QLThumbnail` target's **Build Settings**:
    - `INFOPLIST_FILE` → `QLThumbnail/Info.plist`
    - `CODE_SIGN_ENTITLEMENTS` → `QLThumbnail/QLThumbnail.entitlements`
    - `PRODUCT_BUNDLE_IDENTIFIER` → matches what you set in step 4
    - `MACOSX_DEPLOYMENT_TARGET` → `11.0` (or whatever the host app uses)
11. In **Signing & Capabilities** for `QLThumbnail`, add capability
    **App Groups** and tick the same group the main app uses
    (`group.com.ariomoniri.QuickLookProtein` — rename when you rebrand).
12. Build the host app scheme. Xcode embeds the new extension automatically.

## B. Spotlight indexing extension (`MDImporter`)

Source: [`Xcode/MDImporter/`](../Xcode/MDImporter)

1. **File → New → Target…**
2. Filter "spotlight" → choose **Spotlight Importer Extension** under *macOS*
   (this is `CSImportExtension`, the modern macOS 12+ API — *not* the legacy
   "Spotlight Importer" template which creates a `.mdimporter` bundle).
3. Fill in:
   - Product Name: `MDImporter`
   - Bundle ID: `<your prefix>.QuickLookProtein.MDImporter`
   - Language: Swift
4. **Finish**. Delete the auto-generated source files.
5. Drag into the new target group:
   - `Xcode/MDImporter/ImportExtension.swift`
   - `Xcode/MDImporter/Info.plist`
   - `Xcode/MDImporter/MDImporter.entitlements`
   Target membership = `MDImporter` only.
6. The importer does *not* need the Shared/ helpers — it parses plaintext
   headers itself. Don't add `Shared/` to this target's membership.
7. Build settings:
   - `INFOPLIST_FILE` → `MDImporter/Info.plist`
   - `CODE_SIGN_ENTITLEMENTS` → `MDImporter/MDImporter.entitlements`
   - `PRODUCT_BUNDLE_IDENTIFIER` → matches step 3
   - **`MACOSX_DEPLOYMENT_TARGET` → `12.0`** ⚠️
     `CSImportExtension` is macOS 12+. The host app targets macOS 11, so the
     MDImporter target must override its deployment target to 12.0 or the
     extension's principal class won't be available at runtime and indexing
     will silently fail.
8. The Spotlight importer does *not* need the App Group; remove the
   `application-groups` key from the entitlements file if Xcode added one.
   (It's already absent in the file we ship.)
9. Build the host app scheme.

## Verification after building

Quick Look extension:

```bash
qlmanage -r && qlmanage -r cache
# then in Finder: select a .pdb / .mol2 file, press Space
```

Thumbnail extension:

```bash
qlmanage -r thumbnails
# then in Finder, view a folder of structures in Gallery / Cover Flow
```

Spotlight indexer:

```bash
mdimport -L            # confirms our importer is registered
mdimport ~/some.pdb    # forces re-index of a single file
mdls ~/some.pdb        # shows the indexed metadata
mdfind 'kMDItemKind == "Protein Data Bank file"'
```

## When you rebrand to your own team / bundle prefix

Search-and-replace `FF68N39FU5` and `com.ariomoniri` together across:

- `Xcode/Shared/Settings.swift`
- `Xcode/*.entitlements` (all three)
- `Xcode/QuickLookProtein/Info.plist` (`UTExportedTypeDeclarations`)
- `Xcode/QLExtension/Info.plist` (`QLSupportedContentTypes`)
- `Xcode/QLThumbnail/Info.plist`
- `Xcode/MDImporter/Info.plist`

Then in Xcode → each target → **Signing & Capabilities** → switch the team
and update bundle IDs.
