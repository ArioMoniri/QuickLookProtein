# Roadmap — XTC trajectories & USDZ export

Two acknowledged limitations from the v1.7.41 audit-complete release. Both
are tractable; both were scoped out because the implementation cost was
too high for the "wrap up the audit list" milestone. This document gives a
future contributor a concrete plan.

---

## 1. XTC trajectory previews

✅ Shipped in v1.7.43 — `parseXTCFirstFrame` in
`Xcode/Shared/SharedFunctions.swift` is a faithful port of libxdrfile2's
xdr3dfcoord decompressor. Implementation notes below are kept for
future maintenance.

**Goal.** When the user spacebars a `.xtc` file in Finder, render the first
frame as XYZ in 3Dmol — same UX as the existing DCD and TRR readers.

**Why it's deferred.** XTC is GROMACS's *compressed* trajectory format. Unlike
DCD (Fortran records) and TRR (XDR raw floats), XTC packs coordinates into a
custom bit-stream using `libxdrfile`'s 3DF compression. Decompression is
~250 LOC of bit-twiddling, plus integration tests with non-trivial fixture
files. The format is fully specified — there is no algorithmic unknown — but
porting the reference code carefully takes a focused half-day.

### Format outline

XTC is XDR-framed (always big-endian, 4-byte aligned). Each frame:

| Field | Type | Notes |
|---|---|---|
| `magic` | int32 | `1995` |
| `natoms` | int32 | atom count |
| `step` | int32 | timestep number |
| `time` | float32 | sim time (ps) |
| `box[9]` | float32 | unit cell, row-major |
| `natoms2` | int32 | echo of natoms (sanity check) |

Then if `natoms ≤ 9` the coords are stored as raw `natoms*3` float32; if
`natoms > 9`, the **3DF compressed block** kicks in:

| Field | Type | Notes |
|---|---|---|
| `precision` | float32 | scale factor (typically 1000.0 → mÅ resolution) |
| `minint[3]` | int32 | per-axis minimum integer-scaled coord |
| `maxint[3]` | int32 | per-axis maximum |
| `smallidx` | int32 | index into `magicints[]` table (74 entries) |
| `nbytes` | int32 | length of compressed bitstream that follows |
| `<nbytes bytes>` | binary | the bit-packed coord stream |

### Decompression algorithm

The bit-stream encodes each atom as one of three modes, in order:

1. **Large mode** — 3 integers, each `sizeint[i]` bits wide, where
   `sizeint[i] = ceil(log2(maxint[i] - minint[i] + 1))`. Used for the first
   atom and for atoms that diverged from the previous run.
2. **Small triple** — 3 small ints, each `smallidx`-bit wide, packed via the
   `magicints[]` table. The triple is XOR-style offset against the running
   "thiscoord" anchor.
3. **Run-length** — if the next bits decode to a special "is_smaller"
   signal, the previous small triple repeats with `smallidx` bumped down
   (smaller) or up (larger).

The `magicints[]` table is a fixed 74-entry power-of-cube-root table; copy
it from libxdrfile2 verbatim.

### Implementation plan

Add to `Xcode/Shared/SharedFunctions.swift` (next to `parseTRRFirstFrame`):

```swift
private func parseXTCFirstFrame(data: Data, xtcURL: URL) -> String?
```

Internal helpers:

- `struct BitReader { ... }` — reads `n` bits at a time from a `Data` slice,
  MSB-first per byte. ~25 LOC.
- `readBits(_ n: Int) -> UInt32` and `readInt(_ n: Int) -> Int`.
- The `magicints` table as `static let magicints: [Int] = [ ... 74 entries ... ]`.
- The core unpacking loop, which keeps a `thiscoord[3]` running state and
  emits one Int3 per atom.

Then convert the integer-scaled coords back to Å:

```swift
let scale = 10.0 / Double(precision)   // nm→Å, divide by precision
let x = Double(intX) * scale + Double(minint[0]) * scale
```

The dispatch in `readTrajectoryFirstFrame` flips from:

```swift
case "xtc":
    return nil
```

to:

```swift
case "xtc":
    return parseXTCFirstFrame(data: data, xtcURL: URL(fileURLWithPath: path))
```

And the user-facing error message in `prepare3DmolHTML` drops the "XTC
requires libxdrfile-style decompression" line.

### Test plan

1. **Fixture**: generate a 100-atom, 1-frame XTC from any small protein via:
   ```
   gmx trjconv -f input.gro -o test.xtc -dump 0
   ```
   Commit to `Xcode/QuickLookProtein/SampleAssets/` (a few KB).
2. **Unit test** (new `Xcode/Tests/XTCReaderTests.swift`):
   - Parse the fixture, assert `natoms == expected`.
   - Assert frame-0 coords round-trip within `1/precision` Å of the
     `.gro` source coords.
   - Endian probe: a hand-crafted byte-flipped fixture should return nil
     cleanly rather than crash.
3. **Smoke test**: spacebar the fixture in Finder, confirm rendering
   matches the `.gro` rendering side-by-side.

### Reference

- libxdrfile2 source: <https://github.com/wesbarnett/libxdrfile>
- Algorithm explainer: <https://manual.gromacs.org/current/reference-manual/file-formats.html#xtc>

### Effort estimate

- Bitstream reader: 1h
- `magicints` table + unpacker: 2h
- Plumbing + error paths: 30min
- Tests + fixture: 1h
- **Total: ~half a day** for a Swift-comfortable contributor.

---

## 2. USDZ export from the Share button

✅ Shipped in v1.7.42 — `Xcode/Shared/USDZExporter.swift` builds an
MDLAsset of CPK-coloured spheres from `Xcode/Shared/MoleculeModel.swift`
and writes a `.usdz` alongside the PNG when the share button is
pressed. Implementation notes below are kept for future maintenance.

**Goal.** The in-preview Share button currently captures the WebGL canvas as
PNG and hands it to `NSSharingServicePicker`. Add a parallel USDZ export so
users can AirDrop the molecule to an iPad / iPhone and see it in AR Quick
Look (the Files app auto-promotes `.usdz` to the AR preview flow).

**Why it's deferred.** The PNG path was the v1.7.33 deliverable; USDZ adds a
second exporter that requires a 3D scene representation (not a 2D snapshot),
which means routing atom data from Swift → ModelIO → USD writer. The
ModelIO API itself is straightforward; the wrinkle is sharing the existing
atom-parsing code with `ActionRequestHandler.swift` (QLActions) and
`ThumbnailProvider.swift` (QLThumbnail) without code duplication.

### Approach

**Shared renderer module** — extract atom parsing into a new file:

```
Xcode/Shared/MoleculeModel.swift
```

…containing the `Atom` struct + `parseAtoms(from:ext:)` currently duplicated
across `ThumbnailProvider.swift` and `ActionRequestHandler.swift`. Both targets
add this file to their Compile Sources phase. Existing call sites swap to
`MoleculeModel.parseAtoms(...)`.

**ModelIO bridge** — new file `Xcode/Shared/USDZExporter.swift`:

```swift
import ModelIO
import SceneKit  // for SCNSphere → MDLMesh convenience

enum USDZExporter {
    /// Build an MDLAsset from a list of atoms and write it to a .usdz file.
    static func export(atoms: [Atom], to url: URL) throws {
        let asset = MDLAsset()
        let scale: Float = 0.3  // 0.3 Å per visual unit, matches AR Quick Look conventions

        // One MDLMesh per element; reuse the same geometry, vary transform.
        // (USDZ supports instancing — emit each atom as a separate MDLObject
        // referencing a shared MDLMesh for compactness.)
        let allocator = MTKMeshBufferAllocator(device: MTLCreateSystemDefaultDevice()!)
        let sphereGeom = MDLMesh.newEllipsoid(
            withRadii: SIMD3<Float>(repeating: scale),
            radialSegments: 16, verticalSegments: 8,
            geometryType: .triangles, inwardNormals: false,
            hemisphere: false, allocator: allocator)

        for atom in atoms {
            let object = MDLObject()
            object.addChild(sphereGeom)
            object.transform = MDLTransform(matrix: matrix_translation(
                Float(atom.x), Float(atom.y), Float(atom.z)))
            // Material: CPK color for the element
            let material = MDLMaterial(name: "cpk-\(atom.element)",
                                       scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
            let color = cpkColor(for: atom.element)
            material.setProperty(MDLMaterialProperty(name: "baseColor",
                                                    semantic: .baseColor,
                                                    color: color))
            sphereGeom.submeshes?.forEach { ($0 as? MDLSubmesh)?.material = material }
            asset.add(object)
        }

        try asset.export(to: url)
    }
}
```

(The above is illustrative — `MDLAsset.export(to:)` infers format from the
URL extension. `.usdz` triggers Apple's USD-on-disk archiver. Test that
unsupported elements still get a fallback color.)

**Share-button path** — in `PreviewViewController.swift`, the
`userContentController(_:didReceive:)` handler currently writes the PNG
data URI to a temp file and shows the share picker for `[pngURL]`. Extend
it to also write a `.usdz` next to the PNG and pass **both** items:

```swift
let pngURL = ... // existing
let usdzURL = pngURL.deletingPathExtension().appendingPathExtension("usdz")

if let atoms = self.cachedAtoms {  // re-use the parsed atoms from preview load
    try? USDZExporter.export(atoms: atoms, to: usdzURL)
    NSSharingServicePicker(items: [pngURL, usdzURL]).show(...)
} else {
    NSSharingServicePicker(items: [pngURL]).show(...)
}
```

NSSharingServicePicker auto-filters services per item type — AirDrop will
show both, but the AR-Quick-Look-on-receive flow on iOS picks the `.usdz`.

**Settings toggle** — add `Settings.includeUSDZInShare: Bool` (default `true`).
Wire to ContentView toggle next to "Share button in preview". If `false`,
fall back to PNG-only behavior.

### Caching atom data

The viewer extension currently re-parses the source file in the WebView's
JS side and discards atoms before any share request. To export USDZ we need
the Swift-side atom array at the moment the share button is clicked. Two
options:

1. **Re-parse in Swift on click** — simple, ~20ms for typical proteins, no
   state to manage. Recommended for v1 USDZ.
2. **Cache atoms during preview load** — sligthly faster but adds lifecycle
   state. Skip unless profiling shows option 1 is noticeable.

### Test plan

1. **Unit test** (`Xcode/Tests/USDZExporterTests.swift`): given a 3-atom
   methane fixture, export to USDZ, read back via `MDLAsset(url:)` and
   assert the export round-trips to the same atom count and centroid.
2. **AR Quick Look smoke test** (manual): AirDrop the USDZ from macOS Share
   to an iPad. Open in Files. Confirm the AR badge appears and tapping
   it launches the AR camera preview.
3. **Large-file guard**: a 50k-atom ribosome should either export cleanly
   (preferred) or surface a "structure too large for USDZ — share PNG
   instead" error rather than spinning forever. Set a soft cap at 20k
   atoms; above that, fall back to PNG-only with a one-line message.

### Open questions / risks

- **Bond representation**: spheres alone read fine in AR for small molecules
  but proteins benefit from explicit bonds. v1: spheres only. v2: add
  cylinders between bonded atoms (uses ~3x more geometry).
- **Cartoon ribbons in USDZ**: 3Dmol's WebGL cartoon mesh is generated
  client-side and would need to be re-built Swift-side. Out of scope for
  v1 — proteins export as Cα spheres for now.
- **File size**: a 5000-atom protein with sphere-only USDZ is ~2 MB. Inside
  AirDrop's comfort zone; nothing to do.

### Effort estimate

- `MoleculeModel.swift` extraction: 1h (pure code motion + target membership)
- `USDZExporter.swift`: 2h (ModelIO API + CPK color table)
- Share path wiring + settings toggle: 1h
- Tests + manual AR smoke: 1h
- **Total: ~half a day**.

---

## Priority order

If a future contributor picks this up, do **USDZ first**:

- Smaller blast radius (one share-side path, no parsing-format rabbit hole).
- More user-visible payoff (AR demos sell the app to chemistry students far
  better than the ability to preview one more GROMACS subformat).
- Sets up the `MoleculeModel.swift` shared-renderer extraction, which
  reduces duplication for any other Swift-side exporter we add later
  (glTF, OBJ, FBX).

XTC second:

- Real but narrower audience (GROMACS users; everyone else is on .dcd or
  .pdb-multimodel).
- More self-contained — pure parser, no UI changes.
- Drop the "XTC requires libxdrfile-style decompression" line from the
  trajectory error path when this ships.
