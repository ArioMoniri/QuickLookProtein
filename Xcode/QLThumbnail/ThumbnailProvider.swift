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
//      so WebKit refuses to paint a layer tree against an occluded window
//      and the 5.5 s timeout always fires.
//
//      Instead, parse the file in Swift, decide whether it's a protein
//      (worth a cartoon-style backbone trace) or a small molecule (CPK
//      space-filling spheres), and paint into the QLThumbnailReply
//      context with Core Graphics. The protein cartoon path connects
//      Cα atoms per-chain with a thick rounded stroke coloured by a
//      rainbow gradient along the sequence (N-terminus blue → C-terminus
//      red), which matches the visual convention 3Dmol's cartoon style
//      uses in the Quick Look *preview*.
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

    /// Down-sample non-cartoon (CPK) renders to this atom count for
    /// large structures so the painter's algorithm stays fast.
    private static let maxDrawnAtomsCPK = 800

    /// Heuristic: more Cα atoms than this and we treat the file as a
    /// protein, switching to the ribbon trace style instead of CPK.
    /// Below this we fall through to CPK so e.g. a peptide ligand stays
    /// readable as a real molecule.
    private static let proteinCAThreshold = 25

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {

        let ext = request.fileURL.pathExtension.lowercased()
        let size = request.maximumSize
        os_log("provideThumbnail called for %{public}@ (ext=%{public}@, size=%{public}.0fx%{public}.0f)",
               log: thumbLog, type: .info, request.fileURL.path, ext, size.width, size.height)

        let atoms = Self.parseAtoms(from: request.fileURL, ext: ext)

        // Render to a temp PNG and hand Finder a file URL rather than a
        // drawing block. The `imageFileURL:` initializer tells the system
        // "this is a pre-rendered full-bleed thumbnail" and skips the
        // document-page template wrap that `drawing:` triggers at small
        // list-view icon sizes (the wrap appears as a white page with our
        // thumbnail embedded in the lower half). For icon-view sizes the
        // result is identical; for list-view the URL form is full-bleed.
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qlp-thumb-\(UUID().uuidString).png")

        // Animated APNG path: opt-in via Settings, only at sizes ≥ 128 px
        // (smaller icons aren't worth the 12x render cost). On failure we
        // fall through to the single-frame still.
        // Read settings directly from the App Group container — QLThumbnail
        // doesn't link Settings.swift to keep the extension's footprint tiny.
        let defaults = UserDefaults(suiteName: "FF68N39FU5.group.com.ariomoniri.QuickLookProtein")
            ?? .standard
        let animatedOn = defaults.object(forKey: "animatedThumbnails") as? Bool ?? false
        if animatedOn,
           min(size.width, size.height) >= 128,
           let atoms = atoms, !atoms.isEmpty,
           let apng = Self.renderAPNG(atoms: atoms, ext: ext, size: size) {
            let apngURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("qlp-thumb-\(UUID().uuidString).png")
            do {
                try apng.write(to: apngURL, options: .atomic)
                os_log("returning APNG thumbnail (%{public}@)",
                       log: thumbLog, type: .info, apngURL.path)
                handler(QLThumbnailReply(imageFileURL: apngURL), nil)
                return
            } catch {
                os_log("APNG write failed: %{public}@ — falling back",
                       log: thumbLog, type: .error, error.localizedDescription)
            }
        }

        let renderedOK = Self.renderToPNG(at: tempURL, size: size) { rect in
            if let atoms = atoms, !atoms.isEmpty {
                Self.drawMolecule(atoms: atoms, ext: ext, in: rect)
            } else {
                Self.drawAtomGlyph(ext: ext, in: rect)
            }
        }
        if renderedOK {
            os_log("returning imageFileURL thumbnail (%{public}@)",
                   log: thumbLog, type: .info, tempURL.path)
            handler(QLThumbnailReply(imageFileURL: tempURL), nil)
            return
        }

        // Last-ditch fallback: use the drawing-block init even though it
        // may get the doc-template wrap. Better a wrapped thumbnail than
        // none at all.
        os_log("PNG render failed — falling back to drawing block", log: thumbLog, type: .error)
        let reply = QLThumbnailReply(contextSize: size) { cgCtx -> Bool in
            Self.withNSGraphicsContext(cgCtx) {
                if let atoms = atoms, !atoms.isEmpty {
                    Self.drawMolecule(atoms: atoms, ext: ext,
                                      in: NSRect(origin: .zero, size: size))
                } else {
                    Self.drawAtomGlyph(ext: ext, in: NSRect(origin: .zero, size: size))
                }
            }
            return true
        }
        handler(reply, nil)
    }

    /// Renders `body` into a backed NSBitmapImageRep at the requested
    /// size, writes the PNG to disk, returns true on success. Pre-rendering
    /// like this is how we hand Finder a full-bleed thumbnail via the
    /// `imageFileURL:` init — see the comment in provideThumbnail.
    private static func renderToPNG(at url: URL,
                                    size: CGSize,
                                    body: (NSRect) -> Void) -> Bool {
        guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0)
        else { return false }
        guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        body(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            os_log("PNG write failed: %{public}@", log: thumbLog, type: .error,
                   error.localizedDescription)
            return false
        }
    }

    /// QLThumbnailReply's drawing block receives a raw CGContext — it does
    /// NOT push it into NSGraphicsContext.current the way -[NSImage
    /// lockFocus] would. Our drawing routines use NSGradient / NSBezierPath
    /// / NSAttributedString, all of which paint into the *current*
    /// NSGraphicsContext; if that isn't set, the calls silently no-op and
    /// the thumbnail ships as a 4–5 KB blank PNG.
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
        var element: String       // uppercase, 1–2 chars
        var name: String          // PDB atom name (CA, N, C, O, …) — empty if format has no concept
        var chain: String         // PDB chain ID — empty for small-molecule formats
        var residueSeq: Int       // PDB residue number for ordering Cα atoms; 0 if unknown
    }

    // MARK: - File parsing entry point

    private static func parseAtoms(from url: URL, ext: String) -> [Atom]? {
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

    private static func parsePDB(_ text: String) -> [Atom]? {
        var out: [Atom] = []
        out.reserveCapacity(2048)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let bytes = Array(line.utf8)
            guard bytes.count >= 54 else { continue }
            let recordType = String(decoding: bytes[0..<min(6, bytes.count)], as: UTF8.self)
            guard recordType == "ATOM  " || recordType == "HETATM" else { continue }

            guard let x = parseField(bytes, 30, 38),
                  let y = parseField(bytes, 38, 46),
                  let z = parseField(bytes, 46, 54) else { continue }

            // Atom name (cols 13-16, 0-indexed 12..<16). For Cα atoms it
            // shows up as " CA " — keep whitespace stripped so equality
            // checks against "CA" work regardless of column padding.
            let atomName = bytes.count >= 16
                ? String(decoding: bytes[12..<16], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                : ""

            // Element column 77-78
            var elem = ""
            if bytes.count >= 78 {
                elem = String(decoding: bytes[76..<78], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces).uppercased()
            }
            if elem.isEmpty {
                elem = firstLetters(atomName).uppercased()
            }

            // Chain ID at column 22 (single character, may be blank)
            let chain = bytes.count >= 22
                ? String(decoding: bytes[21..<22], as: UTF8.self)
                : ""

            // Residue sequence number cols 23-26
            let resSeq: Int = {
                guard bytes.count >= 26 else { return 0 }
                return Int(String(decoding: bytes[22..<26], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)) ?? 0
            }()

            out.append(Atom(x: x, y: y, z: z,
                            element: elem.isEmpty ? "C" : elem,
                            name: atomName,
                            chain: chain,
                            residueSeq: resSeq))
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
        for line in lines.dropFirst(2).prefix(count) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let x = Double(parts[1]),
                  let y = Double(parts[2]),
                  let z = Double(parts[3]) else { continue }
            out.append(Atom(x: x, y: y, z: z,
                            element: String(parts[0]).uppercased(),
                            name: "", chain: "", residueSeq: 0))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - MOL / SDF (V2000)

    private static func parseMOLV2000(_ text: String) -> [Atom]? {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 4 else { return nil }
        let countStr = lines[3].prefix(3).trimmingCharacters(in: .whitespaces)
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
                            element: String(parts[3]).uppercased(),
                            name: "", chain: "", residueSeq: 0))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - MOL2 (Tripos)

    private static func parseMOL2(_ text: String) -> [Atom]? {
        var inAtoms = false
        var out: [Atom] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@<TRIPOS>ATOM") { inAtoms = true; continue }
            if line.hasPrefix("@<TRIPOS>") { if inAtoms { break }; continue }
            guard inAtoms else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 6,
                  let x = Double(parts[2]),
                  let y = Double(parts[3]),
                  let z = Double(parts[4]) else { continue }
            let typeStr = String(parts[5])
            let elem = String(typeStr.split(separator: ".").first ?? "C").uppercased()
            out.append(Atom(x: x, y: y, z: z, element: elem,
                            name: "", chain: "", residueSeq: 0))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - GRO (GROMACS)

    private static func parseGRO(_ text: String) -> [Atom]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3 else { return nil }
        guard let count = Int(lines[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        var out: [Atom] = []
        out.reserveCapacity(count)
        for i in 2..<min(2 + count, lines.count) {
            let bytes = Array(lines[i].utf8)
            guard bytes.count >= 44 else { continue }
            let atomName = String(decoding: bytes[10..<15], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard let x = parseField(bytes, 20, 28),
                  let y = parseField(bytes, 28, 36),
                  let z = parseField(bytes, 36, 44) else { continue }
            // GRO is nm; rest of pipeline is Å
            out.append(Atom(x: x * 10, y: y * 10, z: z * 10,
                            element: firstLetters(atomName).uppercased(),
                            name: atomName, chain: "", residueSeq: 0))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Parsing helpers

    private static func parseField(_ bytes: [UInt8], _ lo: Int, _ hi: Int) -> Double? {
        guard hi <= bytes.count else { return nil }
        return Double(String(decoding: bytes[lo..<hi], as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces))
    }

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

    // MARK: - CPK colours (for the sphere render)

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
        let first = String(element.prefix(1))
        return elementColors[first] ?? NSColor.systemPink
    }

    /// Rainbow hue from N-terminus (t=0, blue) through to C-terminus
    /// (t=1, red). Matches 3Dmol's "spectrum" colorscheme so a cartoon
    /// thumbnail and the in-app preview look like the same molecule.
    private static func rainbow(_ t: Double) -> NSColor {
        let clamped = max(0.0, min(1.0, t))
        let hue = (1.0 - clamped) * (240.0 / 360.0)  // 240°=blue → 0°=red
        return NSColor(hue: CGFloat(hue),
                       saturation: 0.85,
                       brightness: 1.0,
                       alpha: 1.0)
    }

    // MARK: - Top-level renderer (decide cartoon vs CPK)

    private static func drawMolecule(atoms: [Atom], ext: String, in rect: NSRect) {
        // Dark gradient background, shared across both render styles.
        NSGradient(starting: NSColor(white: 0.13, alpha: 1.0),
                   ending:   NSColor(white: 0.06, alpha: 1.0))?.draw(in: rect, angle: -90)

        // If the file looks like a protein (enough Cα atoms grouped into
        // chains), render a cartoon-style ribbon trace. Otherwise fall
        // through to CPK space-filling.
        let caAtoms = atoms.filter { $0.name == "CA" && ($0.element == "C" || $0.element == "") }
        if caAtoms.count >= proteinCAThreshold {
            drawCartoonTrace(caAtoms: caAtoms,
                             allAtoms: atoms,
                             ext: ext, in: rect)
        } else {
            drawCPKSpheres(atoms: atoms, ext: ext, in: rect)
        }

        drawFormatLabel(ext: ext, in: rect)
    }

    // MARK: - Cartoon-style ribbon trace

    /// Connect consecutive Cα atoms per chain with a thick rounded
    /// stroke, coloured by a rainbow gradient along the sequence
    /// (N-terminus blue → C-terminus red). Segments are depth-sorted so
    /// the front of the protein layers over the back. HETATM ligands
    /// from `allAtoms` are drawn on top as small CPK spheres so cofactor
    /// binding sites stay visible — matches what 3Dmol's "smart-style"
    /// renders in the live preview.
    private static func drawCartoonTrace(caAtoms: [Atom], allAtoms: [Atom],
                                         ext: String, in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Group Cα atoms by chain and order each chain by residue
        // sequence so the polyline follows the actual chain direction.
        var byChain: [String: [Atom]] = [:]
        for a in caAtoms { byChain[a.chain, default: []].append(a) }
        for k in byChain.keys {
            byChain[k]?.sort { $0.residueSeq < $1.residueSeq }
        }

        // Use the full atom set for the bounding box so ligands don't
        // get clipped by a too-tight backbone-only bbox.
        let bbox = boundingBox(allAtoms)
        let s = min(rect.width, rect.height)
        let labelPad = s >= 64 ? s * 0.14 : 0
        let drawRect = NSRect(x: rect.minX, y: rect.minY + labelPad,
                              width: rect.width, height: rect.height - labelPad)
        let scale = Double(min(drawRect.width, drawRect.height)) * 0.85 / max(bbox.span, 1e-6)

        // Project to 2D + depth keyed by atom index for depth ordering.
        func project(_ a: Atom) -> (px: Double, py: Double, depth: Double) {
            let px = (a.x - bbox.cx) * scale + Double(drawRect.midX)
            let py = (a.y - bbox.cy) * scale + Double(drawRect.midY)
            return (px, py, a.z)
        }

        // Build segments across all chains, each carrying its midpoint
        // depth and N→C-terminus fractional position for rainbow colour.
        struct Segment {
            let a: (px: Double, py: Double, depth: Double)
            let b: (px: Double, py: Double, depth: Double)
            let t: Double  // colour t-value (0..1, average of endpoints)
        }
        var segments: [Segment] = []
        for chainAtoms in byChain.values {
            guard chainAtoms.count >= 2 else { continue }
            let n = chainAtoms.count
            for i in 0..<(n - 1) {
                let ta = Double(i) / Double(n - 1)
                let tb = Double(i + 1) / Double(n - 1)
                segments.append(Segment(
                    a: project(chainAtoms[i]),
                    b: project(chainAtoms[i + 1]),
                    t: (ta + tb) / 2))
            }
        }
        // Painter's algorithm — back segments first
        segments.sort { ($0.a.depth + $0.b.depth) < ($1.a.depth + $1.b.depth) }

        // Stroke width scales with viewport. At 16px icons it's still
        // ~2px which is enough to read as a ribbon trace.
        let ribbonWidth = max(CGFloat(s) * 0.045, 1.5)

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(ribbonWidth)
        for seg in segments {
            ctx.setStrokeColor(rainbow(seg.t).cgColor)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: seg.a.px, y: seg.a.py))
            ctx.addLine(to: CGPoint(x: seg.b.px, y: seg.b.py))
            ctx.strokePath()
        }

        // Small ligand atoms (HETATM that isn't water) painted over the
        // ribbon so cofactor / inhibitor binding sites read on the icon.
        let hetSet: Set<String> = ["HOH", "WAT", "DOD", "H2O"]
        let ligands = allAtoms.filter { atom in
            // Heuristic: anything whose residue number is past the Cα
            // sequence and whose element isn't H/C from protein. We can't
            // re-check "HETATM" because the record-type wasn't stored,
            // so treat as ligand: not a CA, not a backbone N/C/O, element
            // not H or C of a standard residue chain. Simplest readable
            // approximation: any atom whose chain has no Cα atoms with
            // matching residueSeq — i.e. atoms that aren't on the main
            // backbone polyline.
            guard !atom.name.isEmpty else { return false }
            if atom.name == "CA" || atom.name == "N" || atom.name == "C" || atom.name == "O" {
                return false
            }
            return !hetSet.contains(atom.name)
        }
        // Cap ligand atoms to keep render time bounded
        let maxLigands = 200
        let ligandAtoms = ligands.count > maxLigands
            ? Array(ligands.prefix(maxLigands))
            : ligands

        if !ligandAtoms.isEmpty {
            let ligandR = max(ribbonWidth * 0.6, 1.0)
            let projected = ligandAtoms.map { a -> (CGPoint, Double, Atom) in
                let p = project(a)
                return (CGPoint(x: p.px, y: p.py), p.depth, a)
            }.sorted { $0.1 < $1.1 }
            for (point, _, atom) in projected {
                drawShadedSphere(ctx: ctx, center: point, radius: ligandR,
                                 color: colorFor(element: atom.element))
            }
        }
    }

    // MARK: - CPK space-filling (for small molecules)

    private static func drawCPKSpheres(atoms: [Atom], ext: String, in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let working: [Atom]
        if atoms.count > maxDrawnAtomsCPK {
            let stride = max(1, atoms.count / maxDrawnAtomsCPK)
            working = atoms.enumerated().compactMap { idx, a in
                idx % stride == 0 ? a : nil
            }
        } else {
            working = atoms
        }

        let bbox = boundingBox(working)
        let s = min(rect.width, rect.height)
        let labelPad = s >= 64 ? s * 0.14 : 0
        let drawRect = NSRect(x: rect.minX, y: rect.minY + labelPad,
                              width: rect.width, height: rect.height - labelPad)
        let scale = Double(min(drawRect.width, drawRect.height)) * 0.82 / max(bbox.span, 1e-6)
        let atomRadius = max(2.0, scale * 0.6)

        let projected = working.map { a -> (px: Double, py: Double, depth: Double, atom: Atom) in
            let px = (a.x - bbox.cx) * scale + Double(drawRect.midX)
            let py = (a.y - bbox.cy) * scale + Double(drawRect.midY)
            return (px, py, a.z, a)
        }.sorted { $0.depth < $1.depth }

        let zSpan = max(bbox.maxZ - bbox.minZ, 1e-6)
        for p in projected {
            let depthFrac = (p.depth - bbox.minZ) / zSpan
            let bright = 0.55 + 0.45 * depthFrac
            let color = colorFor(element: p.atom.element)
            drawShadedSphere(ctx: ctx,
                             center: CGPoint(x: p.px, y: p.py),
                             radius: atomRadius,
                             color: color.blended(withFraction: CGFloat(1 - bright),
                                                  of: .black) ?? color)
        }
    }

    // MARK: - Geometry helpers

    private struct BBox {
        var cx, cy, span, minZ, maxZ: Double
    }

    private static func boundingBox(_ atoms: [Atom]) -> BBox {
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        var minZ = Double.infinity, maxZ = -Double.infinity
        for a in atoms {
            if a.x < minX { minX = a.x };  if a.x > maxX { maxX = a.x }
            if a.y < minY { minY = a.y };  if a.y > maxY { maxY = a.y }
            if a.z < minZ { minZ = a.z };  if a.z > maxZ { maxZ = a.z }
        }
        return BBox(cx: (minX + maxX) / 2,
                    cy: (minY + maxY) / 2,
                    span: max(maxX - minX, maxY - minY),
                    minZ: minZ, maxZ: maxZ)
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

    private static func drawFormatLabel(ext: String, in rect: NSRect) {
        let s = min(rect.width, rect.height)
        guard s >= 64 else { return }
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

    // MARK: - Glyph fallback (for formats we can't parse)

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

        drawFormatLabel(ext: ext, in: rect)
    }

    // MARK: - APNG multi-frame render

    /// Render 12 rotation frames in 30° steps around the Y axis and stitch
    /// them into a single APNG. Returns nil if any frame fails to encode.
    private static func renderAPNG(atoms: [Atom], ext: String, size: CGSize) -> Data? {
        let frameCount = 12
        var pngFrames: [Data] = []
        pngFrames.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let angle = (Double(i) / Double(frameCount)) * 2 * .pi
            let rotated = rotateAtomsY(atoms, angle: angle)
            guard let pngData = renderPNGData(size: size, body: { rect in
                drawMolecule(atoms: rotated, ext: ext, in: rect)
            }) else { return nil }
            pngFrames.append(pngData)
        }
        return APNGEncoder.encode(frames: pngFrames, frameDelayMs: 60, loop: 0)
    }

    /// Render a single drawing block to an in-memory PNG (instead of writing
    /// to disk). Used to feed APNG frames without N temp files.
    private static func renderPNGData(size: CGSize, body: (NSRect) -> Void) -> Data? {
        guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0),
              let nsCtx = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        body(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Rotate every atom around the Y axis (vertical), preserving residue /
    /// chain metadata so drawCartoonTrace still gets to depth-sort correctly.
    private static func rotateAtomsY(_ atoms: [Atom], angle: Double) -> [Atom] {
        // Centre on the centroid so the rotation is around the molecule, not
        // around the world origin (which might be far from the structure).
        var cx = 0.0, cy = 0.0, cz = 0.0
        for a in atoms { cx += a.x; cy += a.y; cz += a.z }
        let n = Double(atoms.count)
        cx /= n; cy /= n; cz /= n
        let c = cos(angle), s = sin(angle)
        var out = [Atom]()
        out.reserveCapacity(atoms.count)
        for a in atoms {
            let dx = a.x - cx, dz = a.z - cz
            let nx = dx * c + dz * s + cx
            let nz = -dx * s + dz * c + cz
            out.append(Atom(x: nx, y: a.y, z: nz,
                            element: a.element, name: a.name,
                            chain: a.chain, residueSeq: a.residueSeq))
        }
        return out
    }
}
