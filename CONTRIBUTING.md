# Contributing to QuickLookProtein

Thanks for taking the time! This is a small project so the process is
correspondingly informal.

## Reporting bugs

Open an [issue on GitHub](https://github.com/JethroHemmann/QuickLookProtein/issues).
For Quick Look problems, please include:

1. macOS version (e.g. 14.5).
2. Output of `mdls -name kMDItemContentType /path/to/the/file.ext` so we
   can verify the UTI the system assigned.
3. The format / approximate size of the file. A redacted minimal example
   that reproduces the bug is gold.
4. Output of `log show --predicate 'subsystem == "com.apple.quicklook"' --last 1m`
   right after invoking the broken preview, if you can.

## Adding a new file format

The work is usually three small edits:

1. **`Xcode/Shared/Settings.swift`** — extend `Settings.dataFormat(forExtension:)`
   to return the 3Dmol format token, and `SettingsStorage.atomStyle(forExtension:)`
   to pick a sensible default.
2. **`Xcode/QuickLookProtein/Info.plist`** — add a `UTExportedTypeDeclarations`
   entry so the system recognises the extension.
3. **`Xcode/QLExtension/Info.plist`** (and `QLThumbnail/Info.plist`,
   `MDImporter/Info.plist` if you want thumbnails / Spotlight) — add the
   new UTI to `QLSupportedContentTypes` / `CSSupportedContentTypes`.

If 3Dmol's parser needs special options (e.g. XYZ uses
`{assignBonds: true}`), branch on `format` in
`Xcode/Shared/Assets/3Dmol_viewer.html` where `addOpts` is built.

## Adding a new rendering option

1. Add the setting to `SettingsStorage` with an `@AppStorage` backing.
2. Add it to the `ViewerOptions` struct in `SharedFunctions.swift` and to
   `ViewerOptions.from(_:fileExtension:fileName:)`.
3. Add a `{YOUR_FLAG}` placeholder substitution in `prepare3DmolHTML`.
4. Consume it in `Xcode/Shared/Assets/3Dmol_viewer.html`.
5. Add the Toggle / Picker in `Xcode/QuickLookProtein/ContentView.swift`
   under the *Rendering options* form.

## Style

- Swift: keep files under 500 lines. Type-inferred locals fine. No emojis
  in code or commit messages.
- Avoid unnecessary new dependencies — this is a sandboxed app extension,
  every dependency is one more thing to entitle.
- The Quick Look extension is **memory-budgeted (~120 MB on modern macOS)**
  and **must return its `handler` within a few seconds** or the preview
  blanks. Any new code on the QL path should preserve those invariants.

## Running it locally

After building, flush Quick Look + Spotlight caches so they pick up your
new extension binaries:

```bash
qlmanage -r && qlmanage -r cache
mdimport -r /Applications/QuickLookProtein.app/Contents/PlugIns/MDImporter.appex
```

## Testing the loop

A quick smoke matrix to run before submitting a PR:

| File | Why |
|------|-----|
| 1CRN.pdb | Small protein — fast load, cartoon path |
| 1BNA.pdb | DNA — exercises nucleic-acid detection |
| 1A4Y.pdb | Metalloprotein — exercises metal-sphere path |
| 1HVR.pdb | Ligand-bound protein — exercises smart-styling |
| 6OC6.pdb | NMR ensemble — exercises multimodel handling |
| caffeine.mol2 | Small molecule — exercises MOL2 path |
| any.xyz | Atom-only — exercises `assignBonds` |
| any.cube | Volumetric — should fall back to system icon (thumbnail) |
| something > 25 MB | Exercises the size-cap path |

## License

By contributing, you agree your contributions are released under the same
MIT license as the rest of the project (see [LICENSE](LICENSE)).
