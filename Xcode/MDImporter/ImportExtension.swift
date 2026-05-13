//
//  ImportExtension.swift
//  MDImporter
//
//  Indexes molecular-structure file metadata for Spotlight search:
//
//    PDB / .ent:
//      kMDItemTitle         ← TITLE (concatenated)
//      kMDItemIdentifier    ← 4-letter PDB ID from HEADER (cols 63-66)
//      kMDItemKeywords      ← KEYWDS + PDB ID + experimental method + resolution
//      kMDItemDescription   ← COMPND MOLECULE: (concatenated)
//      kMDItemAuthors       ← AUTHOR
//      kMDItemContentCreationDate ← HEADER deposition date
//      kMDItemKind          ← "Protein Data Bank file"
//
//    mmCIF (PDB-derived):
//      title/keywords/description/method/resolution via `_struct.*`, `_exptl.*`,
//      `_reflns.*` etc. Handles single-line, multi-line `;`-blocks, and the basic
//      `loop_` form for `_struct_keywords.text`.
//
//    Small-molecule CIF (CCDC / COD):
//      title from `_chemical_name_common` / `_chemical_name_systematic`,
//      formula from `_chemical_formula_sum` / `_chemical_formula_moiety`,
//      space group, unit cell, CCDC refcode.
//
//    SDF / MOL:
//      Line 1 of each record (multi-record SDFs index up to the first 5 names).
//
//    MOL2 / XYZ: name lines per spec.
//
//  Only reads the first ~64 KB of each file — Spotlight indexes many files at
//  install time and reading a 200 MB PDB to extract a title is wasteful.
//

import CoreSpotlight
import Foundation

@available(macOS 12.0, *)
final class ImportExtension: CSImportExtension {

    /// PDB / mmCIF headers live in the first few KB; beyond that is the coordinate
    /// table. 64 KB is plenty for the metadata fields we care about.
    private let headerByteLimit = 64 * 1024

    override func update(_ attributes: CSSearchableItemAttributeSet,
                         forFileAt contentURL: URL) throws {
        guard let header = readHeader(at: contentURL) else { return }
        let ext = contentURL.pathExtension.lowercased()
        switch ext {
        case "pdb", "ent":   parsePDB(header,  into: attributes)
        case "cif", "mmcif": parseCIF(header,  into: attributes)
        case "sdf":          parseSDF(header,  into: attributes)
        case "mol":          parseSDFOrMOL(header, into: attributes)
        case "mol2":         parseMOL2(header, into: attributes)
        case "xyz":          parseXYZ(header,  into: attributes)
        default:             break
        }
        if attributes.kind == nil {
            attributes.kind = humanFormatName(for: ext)
        }
    }

    // MARK: - File read

    private func readHeader(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data: Data
        if #available(macOS 10.15.4, *) {
            data = (try? handle.read(upToCount: headerByteLimit)) ?? Data()
        } else {
            data = handle.readData(ofLength: headerByteLimit)
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - PDB

    private func parsePDB(_ text: String, into a: CSSearchableItemAttributeSet) {
        var title       = ""
        var compound    = ""
        var keywords    = [String]()
        var authors     = [String]()
        var organisms   = [String]()
        var classification = ""
        var pdbID       = ""
        var depositDate: Date?
        var method      = ""
        var resolution  = ""

        // Reusable formatter for the HEADER date column (DD-MMM-YY).
        let pdbDateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "dd-MMM-yy"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        for raw in text.split(separator: "\n").prefix(800) {
            let line = String(raw)
            guard line.count >= 6 else { continue }
            let tag = line.prefix(6).trimmingCharacters(in: .whitespaces)
            let rest = line.count > 10
                ? String(line.dropFirst(10)).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""

            switch tag {
            case "TITLE":
                title += (title.isEmpty ? "" : " ") + rest
            case "COMPND":
                if let range = rest.range(of: "MOLECULE:") {
                    let after = rest[range.upperBound...]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                    if !after.isEmpty {
                        compound += (compound.isEmpty ? "" : " ") + after
                    }
                }
            case "SOURCE":
                // Look for "ORGANISM_SCIENTIFIC: <name>;" — drop the trailing semicolon.
                if let range = rest.range(of: "ORGANISM_SCIENTIFIC:") {
                    let after = rest[range.upperBound...]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                    if !after.isEmpty {
                        organisms.append(after)
                    }
                }
            case "KEYWDS":
                let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                keywords.append(contentsOf: parts.filter { !$0.isEmpty })
            case "AUTHOR":
                let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                authors.append(contentsOf: parts.filter { !$0.isEmpty })
            case "HEADER":
                // HEADER format (per the PDB spec):
                //   cols 11–50: classification
                //   cols 51–59: deposition date (DD-MMM-YY)
                //   cols 63–66: 4-character PDB ID
                if line.count >= 50 {
                    let cStart = line.index(line.startIndex, offsetBy: 10)
                    let cEnd   = line.index(line.startIndex, offsetBy: 50)
                    classification = String(line[cStart..<cEnd])
                        .trimmingCharacters(in: .whitespaces)
                }
                if line.count >= 59 {
                    let dStart = line.index(line.startIndex, offsetBy: 50)
                    let dEnd   = line.index(line.startIndex, offsetBy: 59)
                    let dateStr = String(line[dStart..<dEnd]).trimmingCharacters(in: .whitespaces)
                    if !dateStr.isEmpty { depositDate = pdbDateFormatter.date(from: dateStr) }
                }
                if line.count >= 66 {
                    let iStart = line.index(line.startIndex, offsetBy: 62)
                    let iEnd   = line.index(line.startIndex, offsetBy: 66)
                    pdbID = String(line[iStart..<iEnd])
                        .trimmingCharacters(in: .whitespaces)
                        .uppercased()
                }
            case "EXPDTA":
                method += (method.isEmpty ? "" : " ") + rest
            case "REMARK":
                // REMARK 2 RESOLUTION line — first numeric token is the resolution in Å.
                // Example: "REMARK   2 RESOLUTION.    1.85 ANGSTROMS."
                if rest.hasPrefix("2 RESOLUTION") || rest.hasPrefix("2 RESOLUTION.") {
                    let tokens = rest.split(whereSeparator: { $0.isWhitespace })
                    for token in tokens.dropFirst() {
                        if let _ = Double(token) { resolution = String(token); break }
                    }
                }
            // Stop scanning once we hit coordinate records — header is over.
            case "ATOM", "HETATM", "MODEL":
                break
            default: break
            }
            if tag == "ATOM" || tag == "HETATM" || tag == "MODEL" { break }
        }

        if !title.isEmpty       { a.title = collapseWhitespace(title) }
        if !compound.isEmpty    { a.contentDescription = collapseWhitespace(compound) }
        else if !classification.isEmpty { a.contentDescription = classification }
        if !pdbID.isEmpty {
            a.identifier = pdbID
            keywords.append(pdbID)
        }
        if !method.isEmpty {
            keywords.append(collapseWhitespace(method))
        }
        if !resolution.isEmpty {
            keywords.append("\(resolution) Å resolution")
        }
        keywords.append(contentsOf: organisms)
        if !keywords.isEmpty    { a.keywords = uniquePreservingOrder(keywords) }
        if !authors.isEmpty     { a.authors  = uniquePreservingOrder(authors)  }
        if let d = depositDate  { a.contentCreationDate = d }
        a.kind = "Protein Data Bank file"
    }

    // MARK: - CIF / mmCIF

    private func parseCIF(_ text: String, into a: CSSearchableItemAttributeSet) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .prefix(3_000)
                        .map(String.init)

        // mmCIF first, falling back to small-mol CIF keys.
        let title = scanCIFValue(lines, key: "_struct.title")
                 ?? scanCIFValue(lines, key: "_struct_title")
                 ?? scanCIFValue(lines, key: "_entity.pdbx_description")
                 ?? scanCIFValue(lines, key: "_chemical_name_common")
                 ?? scanCIFValue(lines, key: "_chemical_name_systematic")
                 ?? scanCIFValue(lines, key: "_publ_section_title")
        if let title = title { a.title = title }

        var keywords = [String]()
        if let kw = scanCIFValue(lines, key: "_struct_keywords.text") {
            keywords.append(contentsOf: splitCIFKeywords(kw))
        }
        if let kwLoop = scanCIFLoopColumn(lines, key: "_struct_keywords.text") {
            keywords.append(contentsOf: kwLoop.flatMap { splitCIFKeywords($0) })
        }

        // Experimental method (mmCIF)
        if let method = scanCIFValue(lines, key: "_exptl.method") {
            keywords.append(method)
        }
        // Resolution (mmCIF)
        if let res = scanCIFValue(lines, key: "_reflns.d_resolution_high")
                  ?? scanCIFValue(lines, key: "_refine.ls_d_res_high") {
            keywords.append("\(res) Å resolution")
        }
        // Deposition date (mmCIF)
        if let dateStr = scanCIFValue(lines, key: "_pdbx_database_status.recvd_initial_deposition_date") {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: dateStr) { a.contentCreationDate = d }
        }
        // PDB accession code from mmCIF
        if let entryID = scanCIFValue(lines, key: "_entry.id") {
            a.identifier = entryID.uppercased()
            keywords.append(entryID.uppercased())
        }

        // Small-molecule CIF (CCDC / COD)
        if let formula = scanCIFValue(lines, key: "_chemical_formula_sum")
                      ?? scanCIFValue(lines, key: "_chemical_formula_moiety")
                      ?? scanCIFValue(lines, key: "_chemical_formula_structural") {
            a.contentDescription = formula
            keywords.append(formula)
        }
        if let spg = scanCIFValue(lines, key: "_symmetry_space_group_name_H-M")
                  ?? scanCIFValue(lines, key: "_space_group.name_H-M_alt") {
            keywords.append(spg)
        }
        if let ccdc = scanCIFValue(lines, key: "_database_code_depnum_ccdc_archive") {
            a.identifier = ccdc
            keywords.append(ccdc)
        }
        if let doi = scanCIFValue(lines, key: "_journal_paper_doi") {
            keywords.append(doi)
        }

        if !keywords.isEmpty {
            a.keywords = uniquePreservingOrder(keywords)
        }
        a.kind = "Crystallographic Information File"
    }

    /// Single-value CIF lookup. Handles both `key  value` on one line and the `key`
    /// followed by `;`-block convention. Returns nil if the key is inside a `loop_`
    /// — those are handled separately by `scanCIFLoopColumn`.
    private func scanCIFValue(_ lines: [String], key: String) -> String? {
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key) else { continue }
            // Walk backwards past sibling `_key` declarations and blank/comment
            // lines to detect a preceding `loop_`. Stopping at `lines[i-1]` only
            // would miss `loop_` followed by multiple key declarations — common
            // in mmCIF where one loop has 5-10 columns.
            var j = i - 1
            var insideLoop = false
            while j >= 0 {
                let prev = lines[j].trimmingCharacters(in: .whitespaces)
                if prev.isEmpty || prev.hasPrefix("#") { j -= 1; continue }
                if prev == "loop_" { insideLoop = true; break }
                if prev.hasPrefix("_") { j -= 1; continue }
                break
            }
            if insideLoop { return nil }
            let after = String(trimmed.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
            if !after.isEmpty { return cleanCIFLiteral(after) }
            for j in (i + 1)..<min(i + 6, lines.count) {
                let next = lines[j].trimmingCharacters(in: .whitespaces)
                if next.isEmpty { continue }
                if next.hasPrefix(";") {
                    var collected = String(next.dropFirst())
                    for k in (j + 1)..<min(j + 40, lines.count) {
                        let n = lines[k]
                        if n.trimmingCharacters(in: .whitespaces) == ";" { break }
                        collected += " " + n.trimmingCharacters(in: .whitespaces)
                    }
                    return collapseWhitespace(collected)
                }
                return cleanCIFLiteral(next)
            }
        }
        return nil
    }

    /// Scan for `loop_` blocks containing the given key. Returns the column of values
    /// (one entry per data row). Handles the simple case of one column per row line —
    /// adequate for `_struct_keywords.text` which is typically single-column.
    private func scanCIFLoopColumn(_ lines: [String], key: String) -> [String]? {
        var i = 0
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "loop_" {
                // Collect the column key list.
                var keys = [String]()
                var j = i + 1
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("_") { keys.append(t); j += 1 }
                    else { break }
                }
                if let idx = keys.firstIndex(of: key) {
                    var values = [String]()
                    while j < lines.count {
                        let t = lines[j].trimmingCharacters(in: .whitespaces)
                        if t.isEmpty || t.hasPrefix("loop_") || t.hasPrefix("_") || t.hasPrefix("data_") { break }
                        // Quoted tokens are atomic; otherwise whitespace-split.
                        let tokens = splitCIFRow(t)
                        if idx < tokens.count {
                            values.append(cleanCIFLiteral(tokens[idx]))
                        }
                        j += 1
                    }
                    if !values.isEmpty { return values }
                }
                i = j
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Split a CIF row respecting `'…'` and `"…"` quoting.
    private func splitCIFRow(_ s: String) -> [String] {
        var out = [String]()
        var current = ""
        var inSingle = false
        var inDouble = false
        for ch in s {
            if !inSingle && ch == "\"" { inDouble.toggle(); continue }
            if !inDouble && ch == "'"  { inSingle.toggle(); continue }
            if !inSingle && !inDouble && ch.isWhitespace {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func cleanCIFLiteral(_ s: String) -> String {
        var v = s
        if v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        } else if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        return collapseWhitespace(v)
    }

    private func splitCIFKeywords(_ s: String) -> [String] {
        s.split(whereSeparator: { ",;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - SDF (multi-record)

    private func parseSDF(_ text: String, into a: CSSearchableItemAttributeSet) {
        var names = [String]()
        var inHeader = true
        var collected = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(2_000) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces) == "$$$$" {
                inHeader = true
                collected = false
                if names.count >= 5 { break }
                continue
            }
            if inHeader && !collected {
                let name = line.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { names.append(name) }
                collected = true
                inHeader = false
            }
        }
        if let first = names.first { a.title = first }
        if names.count > 1 {
            a.keywords = uniquePreservingOrder(names)
            a.contentDescription = "Multi-record SDF (\(names.count)+ molecules)"
        }
        a.kind = "MDL Structure-Data File"
    }

    private func parseSDFOrMOL(_ text: String, into a: CSSearchableItemAttributeSet) {
        if let first = text.split(separator: "\n").first {
            let name = String(first).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { a.title = name }
        }
        a.kind = "MDL Molfile"
    }

    // MARK: - MOL2

    private func parseMOL2(_ text: String, into a: CSSearchableItemAttributeSet) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == "@<TRIPOS>MOLECULE", i + 1 < lines.count {
                let name = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { a.title = name }
                break
            }
        }
        a.kind = "Tripos MOL2 file"
    }

    // MARK: - XYZ

    private func parseXYZ(_ text: String, into a: CSSearchableItemAttributeSet) {
        let lines = text.split(separator: "\n").map(String.init)
        if lines.count >= 2 {
            let comment = lines[1].trimmingCharacters(in: .whitespaces)
            if !comment.isEmpty { a.title = comment }
        }
        a.kind = "XMol XYZ file"
    }

    // MARK: - Helpers

    private func collapseWhitespace(_ s: String) -> String {
        let parts = s.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }

    /// `Array(Set(x))` loses ordering; preserve it so the first-seen keyword appears first.
    private func uniquePreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out = [String]()
        for item in items {
            if seen.insert(item).inserted { out.append(item) }
        }
        return out
    }

    private func humanFormatName(for ext: String) -> String {
        switch ext {
        case "pdb", "ent":   return "Protein Data Bank file"
        case "cif", "mmcif": return "Crystallographic Information File"
        case "sdf":          return "MDL SDF file"
        case "mol":          return "MDL Molfile"
        case "mol2":         return "Tripos MOL2 file"
        case "xyz":          return "XMol XYZ file"
        case "gro":          return "GROMACS structure"
        case "cube", "cub":  return "Gaussian Cube"
        default:             return "Molecular structure"
        }
    }
}
