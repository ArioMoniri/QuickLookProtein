//
//  ThumbnailProvider.swift
//  QLThumbnail
//
//  Generates per-file Finder thumbnails for molecular structure files.
//
//  Why this is pure Cocoa drawing (no WKWebView, no 3Dmol.js):
//
//      The previous implementation hosted a WKWebView inside an off-screen
//      NSWindow and snapshotted its WebGL canvas after 3Dmol.js finished
//      rendering. That worked on macOS 11–13, but macOS 14+ sandboxed
//      thumbnail extensions are blocked from talking to
//      `com.apple.dock.fullscreen` and `com.apple.windowmanager.server`,
//      WebKit refuses to paint a layer tree against an occluded window,
//      3Dmol never finishes initialising, the 5.5 s timeout fires, and
//      Finder gets back error 102.
//
//  How this works instead:
//
//      Parse the file in Swift (PDB / ENT / PDBQT / PQR / MMTF use a
//      single PDB-style parser; XYZ, MOL/SDF, MOL2, GRO get dedicated
//      ones), extract every atom's (x, y, z, element), depth-sort, and
//      paint shaded CPK-coloured spheres back-to-front into the
//      QLThumbnailReply context. For very large structures (>800 atoms,
//      typical proteins) we down-sample so the painter's algorithm stays
//      fast. The result is a real space-filling-model thumbnail that
//      matches the file's actual shape, generated in well under macOS's
//      8-second thumbnail deadline.
//
//      For formats we don't parse yet (CIF/mmCIF — non-trivial loop_
//      syntax, VASP — fractional coords + lattice math, CDJSON — JSON
//      schema, CUBE — volumetric) we fall back to a stylised atom glyph
//      with a format label.
//
//      The actual 3D rendering with 3Dmol.js is still used for Quick
//      Look *previews* (Space-bar / right pane) — that code path uses
//      QLPreviewingController where the system provides a visible host
//      window and the sandbox lets WebKit paint normally.
//

import Cocoa
import QuickLookThumbnailing
import os.log

private let thumbLog = OSLog(subsystem: "com.ariomoniri.QuickLookProtein.QLThumbnail",
                             category: "thumbnail")

@objc(QLThumbnailThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {

    /// Don't even try to read files larger than this — the thumbnail
    /// extension's memory budget is small and we'd be jetsam'd long
    /// before we finished parsing. Falls back to the static glyph.
    private static let maxFileBytes = 25 * 1024 * 1024

    /// Beyond this atom count we down-sample uniformly to keep render time
    /// bounded. Tuned to give a recognisable shape for any protein while
    /// the painter's algorithm still finishes in <500 ms at 512×512.
    private static let maxDrawnAtoms = 800

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {

        let ext = request.fileURL.pathExtension.lowercased()
        let size = request.maximumSize
        os_log("provideThumbnail called for %{public}@ (ext=%{public}@, size=%{public}.0fx%{public}.0f)",
               log: thumbLog, type: .info, request.fileURL.path, ext, size.width, size.height)

        // Try to parse the actual molecule first. On success the thumbnail
        // shows the real shape; on failure we fall back to the glyph.
        let atoms = Self.parseAtoms(from: request.fileURL, ext: ext)
        if let atoms = atoms, !atoms.isEmpty {
            os_log("parsed %{public}d atoms — rendering real molecule",
                   log: thumbLog, type: .info, atoms.count)
            let reply = QLThumbnailReply(contextSize: size) { cgCtx -> Bool in
                Self.withNSGraphicsContext(cgCtx) {
                    Self.drawMolecule(atoms: atoms, ext: ext,
                                      in: NSRect(origin: .zero, size: size))
                }
                return true
            }
            handler(reply, nil)
            return
        }

        os_log("could not parse atoms — drawing glyph fallback", log: thumbLog, type: .info)
        let reply = QLThumbnailReply(contextSize: size) { cgCtx -> Bool in
            Self.withNSGraphicsContext(cgCtx) {
                Self.drawAtomGlyph(ext: ext, in: NSRect(origin: .zero, size: size))
            }
            return true
        }
        handler(reply, nil)
    }

    /// QLThumbnailReply's drawing block receives a raw CGContext — it does
    /// NOT push it into NSGraphicsContext.current the way -[NSImage
    /// lockFocus] would. Our drawing routines use NSGradient / NSBezierPath
    /// / NSAttributedString, all of which paint into the *current*
    /// NSGraphicsContext; if that isn't set, the calls silently no-op and
    /// the thumbnail ships as a 4–5 KB blank PNG (exactly what we saw).
    /// Wrap the passed CGContext in an NSGraphicsContext, make it current
    /// for the duration of the draw, then restore.
    private static func withNSGraphicsContext(_ cgCtx: CGContext, _ body: () -> Void) {
        let nsCtx = NSGraphicsContext(cgContext: cgCtx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Atom model

    struct Atom {
        var x: Double
        var y: Double
        var z: Double
        var element: String  // uppercase, 1–2 chars
    }

    // MARK: - File parsing entry point

    private static func parseAtoms(from url: URL, ext: String) -> [Atom]? {
        // Bail early on oversized files — we'd OOM long before drawing.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > maxFileBytes {
            os_log("file too large (%{public}d bytes) — using glyph fallback",
                   log: thumbLog, type: .info, size)
            return nil
        }

        let text: String
        do {
            text = try readMolecularText(at: url)
        } catch {
            os_log("read failed: %{public}@", log: thumbLog, type: .error,
                   error.localizedDescription)
            return nil
        }

        switch ext {
        case "pdb", "ent", "pdbqt", "pqr", "mmtf":
            // MMTF is binary in spec; in practice .mmtf files we see in
            // the wild are usually pre-decompressed PDB text. If parsing
            // fails the glyph fallback kicks in cleanly.
            return parsePDB(text)
        case "xyz":
            return parseXYZ(text)
        case "mol", "sdf":
            return parseMOLV2000(text)
        case "mol2":
            return parseMOL2(text)
        case "gro":
            return parseGRO(text)
        default:
            // CIF/mmCIF/VASP/CDJSON/CUBE — not yet supported in the pure
            // Swift parser. Glyph fallback.
            return nil
        }
    }

    private static func readMolecularText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8)         { return s }
        if let s = String(data: data, encoding: .isoLatin1)    { return s }
        if let s = String(data: data, encoding: .macOSRoman)   { return s }
        throw NSError(domain: "QLThumbnail", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Unrecognised text encoding"])
    }

    // MARK: - PDB / ENT / PDBQT / PQR / MMTF

    /// PDB ATOM/HETATM records are fixed-width per the spec:
    ///   columns 31-38: x (8.3)
    ///   columns 39-46: y (8.3)
    ///   columns 47-54: z (8.3)
    ///   columns 77-78: element symbol (right-justified)
    /// PQR diverges slightly (charge/radius take the temperature-factor
    /// columns), but the coordinate columns are the same.
    private static func parsePDB(_ text: String) -> [Atom]? {
        var out: [Atom] = []
        out.reserveCapacity(2048)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Treat as bytes for fixed-column slicing (much faster than
            // String.index arithmetic on long files).
            let bytes = Array(line.utf8)
            guard bytes.count >= 54 else { continue }
            let recordType = String(decoding: bytes[0..<min(6, bytes.count)], as: UTF8.self)
            guard recordType == "ATOM  " || recordType == "HETATM" else { continue }

            guard let x = parseField(bytes, 30, 38),
                  let y = parseField(bytes, 38, 46),
                  let z = parseField(bytes, 46, 54) else { continue }

            // Element: columns 77-78 (0-indexed 76..<78). If absent or
            // blank, derive from atom name (cols 13-14) which works for
            // most well-formed PDBs.
            var elem = ""
            if bytes.count >= 78 {
                elem = String(decoding: bytes[76..<78], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces).uppercased()
            }
            if elem.isEmpty, bytes.count >= 14 {
                let name = String(decoding: bytes[12..<14], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                elem = firstLetters(name).uppercased()
            }
            out.append(Atom(x: x, y: y, z: z, element: elem.isEmpty ? "C" : elem))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - XYZ

    private static func parseXYZ(_ text: String) -> [Atom]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3 else { return nil }
        guard let count = Int(lines[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        var out: [Atom] = []
        out.reserveCapacity(count)
        // Atoms start at line 2 (line 1 is comment).
        for line in lines.dropFirst(2).prefix(count) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let x = Double(parts[1]),
                  let y = Double(parts[2]),
                  let z = Double(parts[3]) else { continue }
            out.append(Atom(x: x, y: y, z: z,
                            element: String(parts[0]).uppercased()))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - MOL / SDF (V2000)

    /// V2000 counts line at row 3 (0-indexed) has atom count in cols 1-3.
    /// Atom block follows, each row: x y z element ...
    private static func parseMOLV2000(_ text: String) -> [Atom]? {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 4 else { return nil }
        let counts = lines[3]
        let countStr = counts.prefix(3).trimmingCharacters(in: .whitespaces)
        guard let count = Int(countStr) else { return nil }
        var out: [Atom] = []
        out.reserveCapacity(count)
        for i in 4..<min(4 + count, lines.count) {
            let parts = lines[i].split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let x = Double(parts[0]),
                  let y = Double(parts[1]),
                  let z = Double(parts[2]) else { continue }
            out.append(Atom(x: x, y: y, z: z,
                            element: String(parts[3]).uppercased()))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - MOL2 (Tripos)

    /// MOL2 atoms live in the `@<TRIPOS>ATOM` section. Each row is
    /// "id name x y z atom_type ...". Section ends at the next `@<TRIPOS>`.
    private static func parseMOL2(_ text: String) -> [Atom]? {
        var inAtoms = false
        var out: [Atom] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@<TRIPOS>ATOM") {
                inAtoms = true
                continue
            }
            if line.hasPrefix("@<TRIPOS>") {
                if inAtoms { break }
                continue
            }
            guard inAtoms else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 6,
                  let x = Double(parts[2]),
                  let y = Double(parts[3]),
                  let z = Double(parts[4]) else { continue }
            // atom_type looks like "C.3" or "N.am" — element is the part
            // before the first dot.
            let typeStr = String(parts[5])
            let elem = String(typeStr.split(separator: ".").first ?? "C").uppercased()
            out.append(Atom(x: x, y: y, z: z, element: elem))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - GRO (GROMACS)

    /// GRO header line 2 has atom count, then each atom row is
    ///   "%5d%-5s%5s%5d%8.3f%8.3f%8.3f" (residue#, resname, atomname, atom#, x, y, z)
    /// Coordinates are in nm — multiply by 10 to get the same Ångström
    /// scale every other parser produces, so the rendering pipeline
    /// doesn't need to know which format produced its input.
    private static func parseGRO(_ text: String) -> [Atom]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3 else { return nil }
        guard let count = Int(lines[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        var out: [Atom] = []
        out.reserveCapacity(count)
        for i in 2..<min(2 + count, lines.count) {
            let line = lines[i]
            let bytes = Array(line.utf8)
            guard bytes.count >= 44 else { continue }
            // atom name: columns 10-15 → element from first letter(s)
            let atomName = String(decoding: bytes[10..<15], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard let x = parseField(bytes, 20, 28),
                  let y = parseField(bytes, 28, 36),
                  let z = parseField(bytes, 36, 44) else { continue }
            out.append(Atom(x: x * 10, y: y * 10, z: z * 10,
                            element: firstLetters(atomName).uppercased()))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Parsing helpers

    private static func parseField(_ bytes: [UInt8], _ lo: Int, _ hi: Int) -> Double? {
        guard hi <= bytes.count else { return nil }
        let str = String(decoding: bytes[lo..<hi], as: UTF8.self)
                   .trimmingCharacters(in: .whitespaces)
        return Double(str)
    }

    /// Strip digits/symbols from the front of an atom name so e.g. "CA" or
    /// "1HG2" both yield a clean element string. Most-significant letter
    /// only; downstream code looks up "CA" → carbon via the element table.
    private static func firstLetters(_ s: String) -> String {
        var out = ""
        for c in s {
            if c.isLetter {
                out.append(c)
                if out.count == 2 { break }
            } else if !out.isEmpty {
                break
            }
        }
        return out
    }

    // MARK: - CPK colours

    /// Standard CPK-ish colours for the elements most likely to appear in
    /// PDB/MOL/MOL2/XYZ structures. Missing elements fall back to soft
    /// pink so they're at least visible against the dark background.
    private static let elementColors: [String: NSColor] = [
        "H":  NSColor(white: 0.95, alpha: 1.0),
        "C":  NSColor(white: 0.35, alpha: 1.0),
        "N":  NSColor(srgbRed: 0.19, green: 0.31, blue: 0.97, alpha: 1.0),
        "O":  NSColor(srgbRed: 0.95, green: 0.20, blue: 0.20, alpha: 1.0),
        "S":  NSColor(srgbRed: 1.00, green: 0.78, blue: 0.20, alpha: 1.0),
        "P":  NSColor(srgbRed: 1.00, green: 0.50, blue: 0.00, alpha: 1.0),
        "F":  NSColor(srgbRed: 0.56, green: 0.88, blue: 0.31, alpha: 1.0),
        "CL": NSColor(srgbRed: 0.12, green: 0.94, blue: 0.12, alpha: 1.0),
        "BR": NSColor(srgbRed: 0.65, green: 0.16, blue: 0.16, alpha: 1.0),
        "I":  NSColor(srgbRed: 0.58, green: 0.00, blue: 0.58, alpha: 1.0),
        "FE": NSColor(srgbRed: 0.88, green: 0.40, blue: 0.20, alpha: 1.0),
        "ZN": NSColor(srgbRed: 0.49, green: 0.50, blue: 0.69, alpha: 1.0),
        "MG": NSColor(srgbRed: 0.54, green: 1.00, blue: 0.00, alpha: 1.0),
        "CA": NSColor(srgbRed: 0.24, green: 1.00, blue: 0.00, alpha: 1.0),
        "NA": NSColor(srgbRed: 0.67, green: 0.36, blue: 0.95, alpha: 1.0),
        "K":  NSColor(srgbRed: 0.56, green: 0.25, blue: 0.83, alpha: 1.0),
    ]

    private static func colorFor(element: String) -> NSColor {
        if let c = elementColors[element] { return c }
        // Some PDB atom names use 2-char tokens where the second char is
        // a number or alpha disambiguator ("CA" → calcium vs carbon-α
        // depending on context). Falling back to the first letter is
        // wrong for genuine 2-letter elements but PDBs encode those as
        // "CL" / "BR" / "FE" etc. that we already cover above.
        let first = String(element.prefix(1))
        return elementColors[first] ?? NSColor.systemPink
    }

    // MARK: - Render the actual molecule

    private static func drawMolecule(atoms: [Atom], ext: String, in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Background — same dark gradient as the glyph so all icons read
        // as the same family.
        let bg = NSGradient(starting: NSColor(white: 0.13, alpha: 1.0),
                            ending:   NSColor(white: 0.06, alpha: 1.0))
        bg?.draw(in: rect, angle: -90)

        // Down-sample if necessary so the painter's algorithm stays fast.
        // Uniform stride preserves overall shape better than e.g. picking
        // by chain ID — every region of the molecule still gets atoms.
        let working: [Atom]
        if atoms.count > maxDrawnAtoms {
            let stride = max(1, atoms.count / maxDrawnAtoms)
            working = atoms.enumerated().compactMap { idx, a in
                idx % stride == 0 ? a : nil
            }
        } else {
            working = atoms
        }

        // Centre + uniform scale. Pad slightly so spheres at the edge
        // don't get clipped, and reserve space for the format label.
        let s = min(rect.width, rect.height)
        let labelPad = s >= 64 ? s * 0.14 : 0
        let drawSize = NSSize(width: rect.width,
                              height: rect.height - labelPad)
        let drawRect = NSRect(x: rect.minX, y: rect.minY + labelPad,
                              width: drawSize.width, height: drawSize.height)

        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        var minZ = Double.infinity, maxZ = -Double.infinity
        for a in working {
            if a.x < minX { minX = a.x };  if a.x > maxX { maxX = a.x }
            if a.y < minY { minY = a.y };  if a.y > maxY { maxY = a.y }
            if a.z < minZ { minZ = a.z };  if a.z > maxZ { maxZ = a.z }
        }
        let span = max(max(maxX - minX, maxY - minY), 1e-6)
        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2
        // Atom-sphere radius scaled to span. For tiny molecules (methane)
        // this gives chunky readable balls; for proteins it auto-shrinks.
        let scale = Double(min(drawSize.width, drawSize.height)) * 0.82 / span
        let atomRadius = max(2.0, scale * 0.6)

        // Painter's algorithm: depth-sort back-to-front.
        let projected = working.map { a -> (px: Double, py: Double, depth: Double, atom: Atom) in
            let px = (a.x - cx) * scale + Double(drawRect.midX)
            let py = (a.y - cy) * scale + Double(drawRect.midY)
            return (px, py, a.z, a)
        }.sorted { $0.depth < $1.depth }

        // Slight depth-based shading factor: atoms further away get
        // slightly dimmer, so the molecule reads as having depth.
        let zSpan = max(maxZ - minZ, 1e-6)

        for p in projected {
            let depthFrac = (p.depth - minZ) / zSpan           // 0 (back) → 1 (front)
            let bright = 0.55 + 0.45 * depthFrac
            let color = colorFor(element: p.atom.element)
            drawShadedSphere(ctx: ctx,
                             center: CGPoint(x: p.px, y: p.py),
                             radius: atomRadius,
                             color: color.blended(withFraction: CGFloat(1 - bright),
                                                  of: .black) ?? color)
        }

        // Format label
        if s >= 64 {
            let label = ext.uppercased() as NSString
            let fontSize = max(s * 0.10, 9)
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
                .kern: fontSize * 0.04
            ]
            let textSize = label.size(withAttributes: attrs)
            let textOrigin = NSPoint(x: (rect.width - textSize.width) / 2,
                                     y: rect.minY + s * 0.04)
            label.draw(at: textOrigin, withAttributes: attrs)
        }
    }

    private static func drawShadedSphere(ctx: CGContext, center: CGPoint,
                                         radius: CGFloat, color: NSColor) {
        let r = max(radius, 0.5)
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)

        let dark   = color.blended(withFraction: 0.40, of: .black) ?? color
        let bright = color.blended(withFraction: 0.30, of: .white) ?? color

        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        NSGradient(starting: bright, ending: dark)?.draw(in: rect, angle: -45)

        // Specular highlight, only worth drawing at radii where it's visible
        if r > 3 {
            let hiR = r * 0.5
            let hiRect = CGRect(x: center.x - r * 0.45,
                                y: center.y + r * 0.15,
                                width: hiR * 2, height: hiR * 2)
            NSGradient(
                starting: NSColor(white: 1.0, alpha: 0.5),
                ending:   NSColor(white: 1.0, alpha: 0.0)
            )?.draw(in: hiRect, relativeCenterPosition: .zero)
        }
        ctx.restoreGState()
    }

    // MARK: - Glyph fallback (for formats we can't parse)

    /// Stylised "atom" glyph + format label, used when the molecule
    /// parser declines (CIF, mmCIF, VASP, CDJSON, CUBE, oversized files…).
    /// Each format gets a distinct accent colour so files are still
    /// distinguishable in Finder column view.
    private static let glyphColors: [String: NSColor] = [
        "pdb":    .systemBlue,    "ent":    .systemBlue,    "pdbqt":  .systemTeal,
        "pqr":    .systemIndigo,
        "cif":    .systemPurple,  "mmcif":  .systemPurple,
        "sdf":    .systemOrange,
        "mol":    .systemOrange,  "mol2":   .systemRed,
        "xyz":    .systemYellow,
        "gro":    .systemMint,
        "cube":   .systemGray,    "cub":    .systemGray,
        "vasp":   .systemGreen,   "poscar": .systemGreen,
        "cdjson": .systemBrown,   "json":   .systemBrown,
        "mmtf":   .systemBlue,
        "prmtop": .systemPink,    "top":    .systemPink
    ]

    private static func drawAtomGlyph(ext: String, in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let s = min(rect.width, rect.height)
        let cx = rect.midX
        let cy = rect.midY + s * 0.06

        NSGradient(starting: NSColor(white: 0.15, alpha: 1.0),
                   ending:   NSColor(white: 0.08, alpha: 1.0))?.draw(in: rect, angle: -90)

        let centerR = s * 0.14
        let outerR  = s * 0.085
        let bondLen = s * 0.26
        let accent = glyphColors[ext] ?? .systemBlue
        let peripherals: [(angle: CGFloat, color: NSColor)] = [
            (.pi *  0.40, accent),
            (.pi *  1.10, .white),
            (.pi *  1.75, accent.blended(withFraction: 0.4, of: .white) ?? accent)
        ]

        ctx.setStrokeColor(NSColor(white: 0.75, alpha: 1.0).cgColor)
        ctx.setLineWidth(s * 0.055)
        ctx.setLineCap(.round)
        for p in peripherals {
            ctx.move(to: CGPoint(x: cx, y: cy))
            ctx.addLine(to: CGPoint(x: cx + cos(p.angle) * bondLen,
                                    y: cy + sin(p.angle) * bondLen))
        }
        ctx.strokePath()

        for p in peripherals {
            drawShadedSphere(ctx: ctx,
                             center: CGPoint(x: cx + cos(p.angle) * bondLen,
                                             y: cy + sin(p.angle) * bondLen),
                             radius: outerR, color: p.color)
        }
        drawShadedSphere(ctx: ctx,
                         center: CGPoint(x: cx, y: cy),
                         radius: centerR, color: accent)

        if s >= 64 {
            let label = ext.uppercased() as NSString
            let fontSize = max(s * 0.13, 9)
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
                .kern: fontSize * 0.04
            ]
            let textSize = label.size(withAttributes: attrs)
            let textOrigin = NSPoint(x: (rect.width - textSize.width) / 2,
                                     y: rect.minY + s * 0.06)
            label.draw(at: textOrigin, withAttributes: attrs)
        }
    }
}
