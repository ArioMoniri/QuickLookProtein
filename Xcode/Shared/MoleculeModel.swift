//
//  MoleculeModel.swift
//  Shared (QuickLookProtein, QLExtension)
//
//  Lightweight atom model shared by the Swift-side renderers that need a
//  parsed atom list — primarily the USDZ exporter (1.7.42+). Each of the
//  Quick Look extensions (QLThumbnail, QLActions) still ships its own
//  slim parser tailored to that target's tight binary-size budget, so
//  we deliberately do NOT collapse them onto this module. The duplication
//  buys us per-extension independence: a parser bug in one painter
//  cannot blow up a different extension.
//
//  Shape mirrors the QLThumbnail / QLActions structs closely enough that
//  callers can swap in either; differences are documented inline.
//

import Foundation

/// One parsed atom. Coordinates are in Ångström for every supported
/// input format — GROMACS .gro files (nanometers) are scaled at parse
/// time so downstream consumers don't need a unit flag.
public struct Atom: Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    /// Element symbol, uppercased ("H", "C", "N", "FE", ...). Always
    /// non-empty; falls back to "C" when the source format lacks an
    /// explicit element column and the atom name can't be guessed.
    public var element: String
    /// PDB-style atom name (e.g. "CA"). Empty for formats without a
    /// concept of atom names (XYZ, MOL, MOL2).
    public var name: String
    /// PDB chain ID. Empty for single-chain or non-PDB formats.
    public var chain: String
    /// PDB residue sequence number; 0 if unknown.
    public var residueSeq: Int

    public init(x: Double, y: Double, z: Double,
                element: String,
                name: String = "",
                chain: String = "",
                residueSeq: Int = 0) {
        self.x = x
        self.y = y
        self.z = z
        self.element = element
        self.name = name
        self.chain = chain
        self.residueSeq = residueSeq
    }
}

/// Parse atoms from a structure file. Returns nil on read failure or
/// when the extension isn't one of the formats covered below. Designed
/// to be cheap — the USDZ exporter calls this on the share-button
/// click path where ~20ms latency for a 5000-atom protein is fine.
public enum MoleculeModel {

    /// Maximum file size we'll try to read. The exporter falls back
    /// gracefully if a file is over the cap.
    public static let maxFileBytes: Int = 50 * 1024 * 1024

    public static func parseAtoms(from url: URL, ext: String) -> [Atom]? {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > maxFileBytes {
            return nil
        }
        let text: String
        do {
            text = try readMolecularText(at: url)
        } catch {
            return nil
        }
        switch ext.lowercased() {
        case "pdb", "ent", "pdbqt", "pqr", "mmtf":
            return parsePDB(text)
        case "cif", "mmcif":
            return parseCIF(text)
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

    // MARK: - Reading

    private static func readMolecularText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8)       { return s }
        if let s = String(data: data, encoding: .isoLatin1)  { return s }
        if let s = String(data: data, encoding: .macOSRoman) { return s }
        throw NSError(domain: "MoleculeModel", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Unrecognised text encoding"])
    }

    // MARK: - PDB family

    private static func parsePDB(_ text: String) -> [Atom]? {
        var out: [Atom] = []
        out.reserveCapacity(2048)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let bytes = Array(line.utf8)
            guard bytes.count >= 54 else { continue }
            let rec = String(decoding: bytes[0..<min(6, bytes.count)], as: UTF8.self)
            guard rec == "ATOM  " || rec == "HETATM" else { continue }
            guard let x = parseField(bytes, 30, 38),
                  let y = parseField(bytes, 38, 46),
                  let z = parseField(bytes, 46, 54) else { continue }
            let atomName = bytes.count >= 16
                ? String(decoding: bytes[12..<16], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                : ""
            var elem = ""
            if bytes.count >= 78 {
                elem = String(decoding: bytes[76..<78], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces).uppercased()
            }
            if elem.isEmpty { elem = firstLetters(atomName).uppercased() }
            let chain = bytes.count >= 22
                ? String(decoding: bytes[21..<22], as: UTF8.self)
                : ""
            let resSeq: Int = {
                guard bytes.count >= 26 else { return 0 }
                return Int(String(decoding: bytes[22..<26], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)) ?? 0
            }()
            out.append(Atom(x: x, y: y, z: z,
                            element: elem.isEmpty ? "C" : elem,
                            name: atomName, chain: chain, residueSeq: resSeq))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - mmCIF

    private static func parseCIF(_ text: String) -> [Atom]? {
        var out: [Atom] = []
        let lines = text.components(separatedBy: .newlines)
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
                let chnIdx  = idx("label_asym_id") ?? idx("auth_asym_id")
                let resSIdx = idx("label_seq_id")  ?? idx("auth_seq_id")
                let xIdx = idx("Cartn_x"); let yIdx = idx("Cartn_y"); let zIdx = idx("Cartn_z")
                guard let xi = xIdx, let yi = yIdx, let zi = zIdx else { i = j; continue }
                while j < lines.count {
                    let r = lines[j].trimmingCharacters(in: .whitespaces)
                    if r.isEmpty || r.hasPrefix("#") || r.hasPrefix("loop_") || r.hasPrefix("_") { break }
                    let cols = r.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                    if cols.count > max(xi, yi, zi),
                       let x = Double(cols[xi]), let y = Double(cols[yi]), let z = Double(cols[zi]) {
                        let el   = (elIdx.flatMap { $0 < cols.count ? cols[$0] : nil } ?? "C").uppercased()
                        let name = nameIdx.flatMap { $0 < cols.count ? cols[$0] : nil } ?? ""
                        let chn  = chnIdx.flatMap  { $0 < cols.count ? cols[$0] : nil } ?? ""
                        let resS = resSIdx.flatMap { $0 < cols.count ? cols[$0] : nil } ?? "0"
                        out.append(Atom(x: x, y: y, z: z,
                                        element: el.isEmpty ? "C" : el,
                                        name: name, chain: chn,
                                        residueSeq: Int(resS) ?? 0))
                    }
                    j += 1
                }
                i = j
                continue
            }
            i += 1
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
                            element: String(parts[0]).uppercased()))
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
                            element: String(parts[3]).uppercased()))
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
            out.append(Atom(x: x, y: y, z: z, element: elem))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - GROMACS .gro

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
            // .gro is nm; convert to Å.
            out.append(Atom(x: x * 10, y: y * 10, z: z * 10,
                            element: firstLetters(atomName).uppercased(),
                            name: atomName))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Helpers

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
}
