//
//  ActionRequestHandler.swift
//  QLActions
//
//  Finder Quick Action target (1.7.40+). Right-click a supported
//  molecular file → Quick Actions → "Render Molecule to PNG" pipes
//  through here and writes a side-car PNG next to the source file.
//
//  This target intentionally re-implements a slim renderer instead of
//  linking the QLThumbnail target's ThumbnailProvider so the binary
//  stays small and the Quick Action remains usable even when the
//  thumbnail extension is disabled. The drawing logic is deliberately
//  simple: parse atoms in Swift, paint either CPK spheres or a Cα
//  ribbon trace via Core Graphics. Identical to the QLThumbnail path
//  in spirit; the heuristics (size, palette, Cα threshold) are kept
//  in sync via the version constants below.
//

import Cocoa
import os.log

private let actionLog = OSLog(subsystem: "com.ariomoniri.QuickLookProtein.QLActions",
                              category: "action")

/// Render output dimensions. Matches what Quick Look thumbnails ask
/// for at 1× display density. Users get a 1024 × 1024 PNG next to
/// every selected file. 1024 px is the sweet spot: Finder Quick Look
/// at full size, plenty for inserting into a paper or slide deck,
/// small enough that the file is < 1 MB for almost every protein.
private let renderSide: CGFloat = 1024

/// File extensions this Quick Action accepts. Aligned with the
/// QLExtension / QLThumbnail UTI set so the Service activation rule
/// (declared in Info.plist) cannot leak through to incompatible files.
private let acceptedExtensions: Set<String> = [
    "pdb", "ent", "pdbqt", "pqr",
    "cif", "mmcif",
    "sdf", "mol", "mol2",
    "xyz", "gro", "cube", "cub",
    "vasp", "poscar",
    "cdjson", "mmtf",
]

/// Threshold for "this is a protein, ribbon-trace it" vs "this is a
/// small molecule, paint CPK". Same number QLThumbnail uses.
private let proteinCAThreshold = 25

/// Parsed atom record. Lean: just what the painter needs.
private struct Atom {
    let element: String   // "C", "N", "O", ... (uppercased)
    let resName: String   // "ALA", "HOH", ...
    let chain:   String   // "A", "B", ...
    let isCA:    Bool     // CA backbone carbon of a polymer
    let x: CGFloat
    let y: CGFloat
    let z: CGFloat
}

@objc(QLActionsRequestHandler)
final class ActionRequestHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        os_log("Quick Action beginRequest, %d items",
               log: actionLog, type: .info, context.inputItems.count)

        let items = (context.inputItems as? [NSExtensionItem]) ?? []
        var rendered = 0
        var selectedURLs: [URL] = []
        let urlsLock = NSLock()
        let group = DispatchGroup()

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                // The Services framework hands us NSItemProvider whose
                // typeIdentifier is `public.file-url`. Load the URL
                // synchronously per attachment - users invoke this on
                // a small selection, parallelism not worth it here.
                let typeID = "public.file-url"
                guard provider.hasItemConformingToTypeIdentifier(typeID) else { continue }
                group.enter()
                provider.loadItem(forTypeIdentifier: typeID, options: nil) { (item, _) in
                    defer { group.leave() }
                    let url: URL?
                    if let direct = item as? URL { url = direct }
                    else if let d = item as? Data, let parsed = URL(dataRepresentation: d, relativeTo: nil) { url = parsed }
                    else { url = nil }
                    guard let fileURL = url else { return }
                    urlsLock.lock()
                    selectedURLs.append(fileURL)
                    urlsLock.unlock()
                    if Self.renderSideCarPNG(for: fileURL) {
                        rendered += 1
                    }
                }
            }
        }

        // Wait for all attachment loads to complete before completing
        // the extension request. macOS spins our process down the
        // instant we complete, so any in-flight loads would be lost.
        group.wait()

        // (1.7.45+) Multi-file merge for spacebar's sandbox limit: when
        // the user selects 2+ compatible molecule files and runs the
        // Quick Action, also emit a `merged.pdb` next to the first file
        // that concatenates each as its own MODEL. Spacebar-previewing
        // the merged file shows them stacked in one scene — which is
        // what Quick Look's "Merge all in same folder" mode tries to
        // do but can't because of the per-file sandbox grant.
        if selectedURLs.count >= 2 {
            if Self.writeMergedPDB(from: selectedURLs) {
                os_log("Wrote merged.pdb from %d files",
                       log: actionLog, type: .info, selectedURLs.count)
            }
        }

        os_log("Quick Action rendered %d/%d files",
               log: actionLog, type: .info, rendered, items.count)
        context.completeRequest(returningItems: context.inputItems, completionHandler: nil)
    }

    /// Concatenate the selected files as a multi-MODEL PDB written next
    /// to the first file as `<firstBase>-merged.pdb`. Skips files we
    /// can't parse into atoms; writes nothing if fewer than 2 produce
    /// usable atoms.
    private static func writeMergedPDB(from urls: [URL]) -> Bool {
        var models: [(name: String, atoms: [Atom])] = []
        for u in urls {
            let ext = u.pathExtension.lowercased()
            guard acceptedExtensions.contains(ext),
                  let atoms = parseAtoms(at: u, ext: ext),
                  !atoms.isEmpty
            else { continue }
            models.append((u.deletingPathExtension().lastPathComponent, atoms))
        }
        guard models.count >= 2, let first = urls.first else { return false }

        var text = "REMARK   QuickLookProtein merged Quick Action — \(models.count) models\n"
        var modelIdx = 1
        for m in models {
            text += "MODEL     \(modelIdx)\n"
            text += "REMARK   model name: \(m.name)\n"
            var serial = 1
            for atom in m.atoms {
                // PDB ATOM line: 30-37 / 38-45 / 46-53 = 8.3f x,y,z
                let elemPad = String(atom.element.prefix(2)).padding(toLength: 2, withPad: " ", startingAt: 0)
                let line = String(format:
                    "ATOM  %5d  %-3s %-3s A%4d    %8.3f%8.3f%8.3f  1.00  0.00          %@",
                    serial,
                    (atom.name.isEmpty ? atom.element : String(atom.name.prefix(3))) as CVarArg,
                    "MOL" as CVarArg,
                    modelIdx,
                    atom.x, atom.y, atom.z,
                    elemPad)
                text += line + "\n"
                serial += 1
            }
            text += "ENDMDL\n"
            modelIdx += 1
        }
        text += "END\n"

        let outURL = first.deletingPathExtension()
            .deletingLastPathComponent()
            .appendingPathComponent("\(first.deletingPathExtension().lastPathComponent)-merged.pdb")
        do {
            try text.write(to: outURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            os_log("merged.pdb write failed: %{public}@",
                   log: actionLog, type: .error, error.localizedDescription)
            return false
        }
    }

    /// Render a single source file to `<source>-render.png` next to
    /// it. Returns true on success. Failures are silent (we can't
    /// surface UI from a Service extension); the user notices because
    /// the PNG is missing.
    private static func renderSideCarPNG(for fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        guard acceptedExtensions.contains(ext) else {
            os_log("skip unsupported ext %{public}@",
                   log: actionLog, type: .info, ext)
            return false
        }
        guard let atoms = parseAtoms(at: fileURL, ext: ext), !atoms.isEmpty else {
            os_log("no atoms parsed from %{public}@",
                   log: actionLog, type: .info, fileURL.lastPathComponent)
            return false
        }
        let isProtein = atoms.lazy.filter { $0.isCA }.count >= proteinCAThreshold
        guard let image = drawMolecule(atoms: atoms, asProtein: isProtein) else { return false }

        let parent = fileURL.deletingLastPathComponent()
        let base   = fileURL.deletingPathExtension().lastPathComponent
        let outURL = parent.appendingPathComponent("\(base)-render.png")
        return writePNG(image: image, to: outURL)
    }

    // MARK: - Parsing
    //
    // We only need atom coordinates + element + residue + chain +
    // CA-flag for the painter. The shared Swift parser in
    // SharedFunctions.swift is heavyweight (handles every 3Dmol
    // format quirk); this slim version covers PDB / CIF / MOL / SDF /
    // XYZ / GRO well enough for a still render. Anything we can't
    // parse falls back to ATOM-line heuristics so we degrade
    // gracefully on unusual formats.
    private static func parseAtoms(at url: URL, ext: String) -> [Atom]? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        switch ext {
        case "pdb", "ent", "pdbqt", "pqr": return parsePDB(raw)
        case "cif", "mmcif":               return parseCIF(raw)
        case "xyz":                        return parseXYZ(raw)
        case "gro":                        return parseGRO(raw)
        default:                           return parsePDB(raw) // many formats are PDB-shaped
        }
    }

    private static func parsePDB(_ raw: String) -> [Atom] {
        var out: [Atom] = []
        raw.enumerateLines { line, _ in
            guard line.hasPrefix("ATOM") || line.hasPrefix("HETATM") else { return }
            guard line.count >= 54 else { return }
            let atomName = line.fieldSubstring(12, 16).trimmingCharacters(in: .whitespaces)
            let resName  = line.fieldSubstring(17, 20).trimmingCharacters(in: .whitespaces)
            let chain    = line.fieldSubstring(21, 22).trimmingCharacters(in: .whitespaces)
            let xs       = line.fieldSubstring(30, 38).trimmingCharacters(in: .whitespaces)
            let ys       = line.fieldSubstring(38, 46).trimmingCharacters(in: .whitespaces)
            let zs       = line.fieldSubstring(46, 54).trimmingCharacters(in: .whitespaces)
            guard let x = Double(xs), let y = Double(ys), let z = Double(zs) else { return }
            let element  = elementFromAtomName(atomName)
            out.append(Atom(element: element, resName: resName, chain: chain,
                            isCA: atomName == "CA",
                            x: CGFloat(x), y: CGFloat(y), z: CGFloat(z)))
        }
        return out
    }

    private static func parseCIF(_ raw: String) -> [Atom] {
        // mmCIF atom_site loops are columnar text. We look for the
        // loop header, identify the columns we need, then parse rows
        // until a blank line or the next "loop_". Good-enough for the
        // RCSB-shaped CIFs almost all users feed in.
        var out: [Atom] = []
        let lines = raw.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let l = lines[i].trimmingCharacters(in: .whitespaces)
            if l == "loop_" {
                var headers: [String] = []
                var j = i + 1
                while j < lines.count {
                    let h = lines[j].trimmingCharacters(in: .whitespaces)
                    if h.hasPrefix("_atom_site.") { headers.append(h); j += 1 }
                    else { break }
                }
                guard !headers.isEmpty else { i += 1; continue }
                let idx = { (key: String) -> Int? in headers.firstIndex(of: "_atom_site.\(key)") }
                let elIdx   = idx("type_symbol")
                let nameIdx = idx("label_atom_id") ?? idx("auth_atom_id")
                let resIdx  = idx("label_comp_id") ?? idx("auth_comp_id")
                let chnIdx  = idx("label_asym_id") ?? idx("auth_asym_id")
                let xIdx    = idx("Cartn_x"), yIdx = idx("Cartn_y"), zIdx = idx("Cartn_z")
                guard let xi = xIdx, let yi = yIdx, let zi = zIdx else { i = j; continue }
                while j < lines.count {
                    let r = lines[j].trimmingCharacters(in: .whitespaces)
                    if r.isEmpty || r.hasPrefix("#") || r.hasPrefix("loop_") || r.hasPrefix("_") { break }
                    let cols = r.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                    if cols.count > max(xi, yi, zi),
                       let x = Double(cols[xi]), let y = Double(cols[yi]), let z = Double(cols[zi]) {
                        let el   = (elIdx.flatMap { $0 < cols.count ? cols[$0] : nil } ?? "C").uppercased()
                        let name = nameIdx.flatMap { $0 < cols.count ? cols[$0] : nil } ?? ""
                        let res  = resIdx.flatMap  { $0 < cols.count ? cols[$0] : nil } ?? ""
                        let chn  = chnIdx.flatMap  { $0 < cols.count ? cols[$0] : nil } ?? "A"
                        out.append(Atom(element: el, resName: res, chain: chn,
                                        isCA: name == "CA",
                                        x: CGFloat(x), y: CGFloat(y), z: CGFloat(z)))
                    }
                    j += 1
                }
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    private static func parseXYZ(_ raw: String) -> [Atom] {
        var out: [Atom] = []
        let lines = raw.components(separatedBy: .newlines)
        // First line: atom count. Second: comment. Then atoms.
        guard lines.count > 2 else { return [] }
        for line in lines.dropFirst(2) {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 4,
                  let x = Double(cols[1]), let y = Double(cols[2]), let z = Double(cols[3]) else { continue }
            let el = cols[0].uppercased()
            out.append(Atom(element: el, resName: "", chain: "A",
                            isCA: false, x: CGFloat(x), y: CGFloat(y), z: CGFloat(z)))
        }
        return out
    }

    private static func parseGRO(_ raw: String) -> [Atom] {
        // GROMACS coords are in nm, fixed-width per line, header +
        // count + atoms + box. Multiply by 10 → Angstroms.
        var out: [Atom] = []
        let lines = raw.components(separatedBy: .newlines)
        guard lines.count > 3 else { return [] }
        let countLine = lines[1].trimmingCharacters(in: .whitespaces)
        guard let n = Int(countLine) else { return [] }
        let body = lines.dropFirst(2).prefix(n)
        for line in body {
            guard line.count >= 44 else { continue }
            let resName = line.fieldSubstring(5, 10).trimmingCharacters(in: .whitespaces)
            let atomName = line.fieldSubstring(10, 15).trimmingCharacters(in: .whitespaces)
            let xs = line.fieldSubstring(20, 28).trimmingCharacters(in: .whitespaces)
            let ys = line.fieldSubstring(28, 36).trimmingCharacters(in: .whitespaces)
            let zs = line.fieldSubstring(36, 44).trimmingCharacters(in: .whitespaces)
            guard let x = Double(xs), let y = Double(ys), let z = Double(zs) else { continue }
            out.append(Atom(element: elementFromAtomName(atomName), resName: resName, chain: "A",
                            isCA: atomName == "CA",
                            x: CGFloat(x * 10), y: CGFloat(y * 10), z: CGFloat(z * 10)))
        }
        return out
    }

    /// Element from atom name (PDB: cols 13-16, GRO: 11-15). Strip
    /// digits then take the first 1-2 alphabetic chars.
    private static func elementFromAtomName(_ name: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespaces).uppercased()
        if clean.isEmpty { return "C" }
        let letters = clean.unicodeScalars.prefix { CharacterSet.letters.contains($0) }
        let s = String(String.UnicodeScalarView(letters))
        if s.count >= 2, twoLetterElements.contains(String(s.prefix(2))) {
            return String(s.prefix(2))
        }
        return String(s.prefix(1))
    }

    private static let twoLetterElements: Set<String> = [
        "HE","LI","BE","NE","NA","MG","AL","SI","CL","AR","CA","SC","TI",
        "CR","MN","FE","CO","NI","CU","ZN","GA","GE","AS","SE","BR","KR",
        "RB","SR","ZR","NB","MO","TC","RU","RH","PD","AG","CD","IN","SN",
        "SB","TE","XE","CS","BA","LA","CE","PR","ND","PM","SM","EU","GD",
        "TB","DY","HO","ER","TM","YB","LU","HF","TA","RE","OS","IR","PT",
        "AU","HG","TL","PB","BI","PO","AT","RN","FR","RA","AC","TH","PA",
        "NP","PU","AM","CM","BK","CF","ES","FM",
    ]

    // MARK: - Drawing

    private static func drawMolecule(atoms: [Atom], asProtein: Bool) -> NSImage? {
        let cs    = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = Int(renderSide) * 4
        guard let ctx = CGContext(data: nil, width: Int(renderSide), height: Int(renderSide),
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // Background.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: renderSide, height: renderSide))

        // Compute centroid + scale to fit a 0.8 × canvas circle.
        var minX = atoms[0].x, maxX = atoms[0].x
        var minY = atoms[0].y, maxY = atoms[0].y
        var minZ = atoms[0].z, maxZ = atoms[0].z
        for a in atoms {
            minX = min(minX, a.x); maxX = max(maxX, a.x)
            minY = min(minY, a.y); maxY = max(maxY, a.y)
            minZ = min(minZ, a.z); maxZ = max(maxZ, a.z)
        }
        let extent = max(maxX - minX, max(maxY - minY, maxZ - minZ))
        guard extent > 0 else { return nil }
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2, cz = (minZ + maxZ) / 2
        let scale = (renderSide * 0.8) / extent

        // Map atom coords → canvas. Z is mapped to brightness so depth
        // reads in a flat 2D paint.
        func project(_ a: Atom) -> (x: CGFloat, y: CGFloat, depth: CGFloat) {
            let x = (a.x - cx) * scale + renderSide / 2
            let y = (a.y - cy) * scale + renderSide / 2
            let depth = (a.z - minZ) / max(1e-6, (maxZ - minZ))
            return (x, y, depth)
        }

        if asProtein {
            // Cα ribbon trace. Group by chain, sort by residue order
            // (we have no explicit residue index, so trust file
            // ordering), draw a thick spline-ish polyline through Cα
            // atoms colored N→C-terminus by hue.
            let cas = atoms.filter { $0.isCA }
            let byChain = Dictionary(grouping: cas, by: { $0.chain })
            for (_, chainAtoms) in byChain {
                guard chainAtoms.count > 1 else { continue }
                ctx.setLineWidth(8)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                for i in 0..<(chainAtoms.count - 1) {
                    let a = chainAtoms[i], b = chainAtoms[i + 1]
                    let (ax, ay, _) = project(a)
                    let (bx, by, _) = project(b)
                    // Hue along the chain: blue (N-term) → red (C-term).
                    let t = CGFloat(i) / CGFloat(chainAtoms.count - 1)
                    let hue = (2.0 / 3.0) * (1 - t)   // 0.666 (blue) → 0 (red)
                    ctx.setStrokeColor(NSColor(calibratedHue: hue, saturation: 0.85,
                                                brightness: 0.85, alpha: 1).cgColor)
                    ctx.move(to: CGPoint(x: ax, y: ay))
                    ctx.addLine(to: CGPoint(x: bx, y: by))
                    ctx.strokePath()
                }
            }
        } else {
            // CPK spheres. Painter's algorithm: sort by Z descending
            // so closer atoms paint over farther ones.
            let sorted = atoms.sorted { $0.z > $1.z }
            let radiusBase = max(3, renderSide * 0.012)
            for a in sorted {
                let (x, y, depth) = project(a)
                let r = radiusBase * elementRadius(a.element)
                let fill = elementColor(a.element).blended(withFraction: 0.25 * (1 - depth),
                                                             of: .black) ?? elementColor(a.element)
                ctx.setFillColor(fill.cgColor)
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
                ctx.setLineWidth(1.0)
                ctx.strokeEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        }

        guard let img = ctx.makeImage() else { return nil }
        return NSImage(cgImage: img, size: NSSize(width: renderSide, height: renderSide))
    }

    private static func elementColor(_ el: String) -> NSColor {
        switch el {
        case "H":  return NSColor.white
        case "C":  return NSColor(calibratedRed: 0.30, green: 0.30, blue: 0.30, alpha: 1)
        case "N":  return NSColor(calibratedRed: 0.19, green: 0.31, blue: 0.97, alpha: 1)
        case "O":  return NSColor(calibratedRed: 0.94, green: 0.05, blue: 0.05, alpha: 1)
        case "S":  return NSColor(calibratedRed: 1.00, green: 0.79, blue: 0.20, alpha: 1)
        case "P":  return NSColor(calibratedRed: 1.00, green: 0.50, blue: 0.00, alpha: 1)
        case "F":  return NSColor(calibratedRed: 0.56, green: 0.88, blue: 0.31, alpha: 1)
        case "CL": return NSColor(calibratedRed: 0.12, green: 0.94, blue: 0.12, alpha: 1)
        case "BR": return NSColor(calibratedRed: 0.65, green: 0.16, blue: 0.16, alpha: 1)
        case "I":  return NSColor(calibratedRed: 0.58, green: 0.00, blue: 0.58, alpha: 1)
        case "FE": return NSColor(calibratedRed: 0.88, green: 0.40, blue: 0.20, alpha: 1)
        case "ZN": return NSColor(calibratedRed: 0.49, green: 0.50, blue: 0.69, alpha: 1)
        case "MG": return NSColor(calibratedRed: 0.54, green: 1.00, blue: 0.00, alpha: 1)
        case "CA": return NSColor(calibratedRed: 0.24, green: 1.00, blue: 0.00, alpha: 1)
        default:   return NSColor(calibratedRed: 0.70, green: 0.50, blue: 0.85, alpha: 1)
        }
    }

    private static func elementRadius(_ el: String) -> CGFloat {
        switch el {
        case "H":  return 0.55
        case "C":  return 1.00
        case "N":  return 0.95
        case "O":  return 0.93
        case "S":  return 1.20
        case "P":  return 1.20
        default:   return 1.05
        }
    }

    private static func writePNG(image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let png  = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            os_log("PNG write failed: %{public}@",
                   log: actionLog, type: .error, error.localizedDescription)
            return false
        }
    }
}

// MARK: - Column-substring helper for fixed-width PDB / GRO lines

private extension String {
    /// Substring by column indices [start, end). Returns "" if the
    /// line is too short to cover the range.
    func fieldSubstring(_ start: Int, _ end: Int) -> String {
        let chars = Array(self)
        guard start < chars.count else { return "" }
        let lo = chars.index(chars.startIndex, offsetBy: start)
        let hi = chars.index(chars.startIndex, offsetBy: min(end, chars.count))
        return String(chars[lo..<hi])
    }
}
