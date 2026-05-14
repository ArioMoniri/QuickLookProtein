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

    /// PDB / mmCIF headers + SEQRES live in the first dozens of KB. We also sample
    /// a few hundred ATOM CA records so we can compute mean B-factor (pLDDT detector
    /// for AlphaFold), so 256 KB is the sweet spot between coverage and Spotlight
    /// install-time throughput.
    private let headerByteLimit = 256 * 1024

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

        // Sequence (SEQRES → 1-letter, per chain), ligand inventory (HETNAM), and
        // quality metadata (REMARK 3 R-free / R-work, mean CA B-factor → pLDDT).
        var seqresByChain: [String: String] = [:]
        var ligands: [String: String] = [:]   // 3-letter code → name
        var rFree   = ""
        var rWork   = ""
        var bFactorSum: Double = 0
        var bFactorCount: Int  = 0
        var bFactorMax: Double = 0
        // Cap CA samples so we don't pay for a 1M-atom file at Spotlight install time.
        let maxBFactorSamples = 500

        // Reusable formatter for the HEADER date column (DD-MMM-YY).
        let pdbDateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "dd-MMM-yy"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        // Walk more lines than before so SEQRES & a B-factor sample window fit.
        for raw in text.split(separator: "\n").prefix(8_000) {
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
                // REMARK 3 captures refinement statistics. Two common spellings:
                //   "FREE R VALUE                     :  0.234"
                //   "R VALUE            (WORKING SET) :  0.198"
                if rest.hasPrefix("3 ") {
                    let upper = rest.uppercased()
                    if upper.contains("FREE R VALUE") && !upper.contains("ERROR") && !upper.contains("BIN") {
                        if let v = lastNumericToken(upper), v > 0 && v < 1 {
                            rFree = formatRValue(v)
                        }
                    } else if upper.contains("R VALUE") && upper.contains("WORKING SET") {
                        if let v = lastNumericToken(upper), v > 0 && v < 1 {
                            rWork = formatRValue(v)
                        }
                    }
                }
            case "SEQRES":
                // Cols 12-13 chain ID; remainder is up to 13 three-letter codes
                // separated by whitespace. We translate to one-letter and append.
                if line.count >= 19 {
                    let chainIdx = line.index(line.startIndex, offsetBy: 11)
                    let chain = String(line[chainIdx]).trimmingCharacters(in: .whitespaces)
                    let body  = line.count > 19
                        ? String(line.dropFirst(19))
                        : ""
                    let codes = body.split(whereSeparator: { $0.isWhitespace })
                    var one = ""
                    for code in codes {
                        one.append(threeLetterToOne(String(code)))
                    }
                    if !one.isEmpty {
                        seqresByChain[chain.isEmpty ? "A" : chain, default: ""] += one
                    }
                }
            case "HETNAM":
                // "HETNAM     ATP  ADENOSINE-5'-TRIPHOSPHATE" — cols 12-14 are
                // the 3-letter code, the rest is the human name. Multi-line
                // continuations get concatenated by 3-letter code.
                if line.count >= 14 {
                    let cStart = line.index(line.startIndex, offsetBy: 11)
                    let cEnd   = line.index(line.startIndex, offsetBy: 14)
                    let code = String(line[cStart..<cEnd])
                        .trimmingCharacters(in: .whitespaces)
                        .uppercased()
                    let nameStart = line.index(line.startIndex, offsetBy: 14)
                    let name = String(line[nameStart...])
                        .trimmingCharacters(in: .whitespaces)
                    if !code.isEmpty && code != "HOH" && code != "WAT" && code != "DOD" {
                        ligands[code, default: ""] += (ligands[code]?.isEmpty == false ? " " : "") + name
                    }
                }
            case "ATOM":
                // Sample CA temperature factors. Per the PDB spec:
                //   cols 13-16 atom name, cols 61-66 temperature factor.
                if bFactorCount < maxBFactorSamples && line.count >= 66 {
                    let nStart = line.index(line.startIndex, offsetBy: 12)
                    let nEnd   = line.index(line.startIndex, offsetBy: 16)
                    let atomName = String(line[nStart..<nEnd]).trimmingCharacters(in: .whitespaces)
                    if atomName == "CA" {
                        let bStart = line.index(line.startIndex, offsetBy: 60)
                        let bEnd   = line.index(line.startIndex, offsetBy: 66)
                        let bStr = String(line[bStart..<bEnd]).trimmingCharacters(in: .whitespaces)
                        if let b = Double(bStr) {
                            bFactorSum += b
                            bFactorCount += 1
                            if b > bFactorMax { bFactorMax = b }
                        }
                    }
                }
            case "HETATM", "MODEL":
                break
            default: break
            }
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
        if !rFree.isEmpty { keywords.append("R-free \(rFree)") }
        if !rWork.isEmpty { keywords.append("R-work \(rWork)") }

        // pLDDT detection: AlphaFold puts confidence in the B-factor column on
        // a 0-100 scale. If mean is in [40,100] and max ≤ 100, treat as pLDDT.
        if bFactorCount > 0 {
            let mean = bFactorSum / Double(bFactorCount)
            if mean >= 40 && mean <= 100 && bFactorMax <= 100 {
                keywords.append(String(format: "pLDDT %.0f", mean))
                keywords.append("AlphaFold")
            } else {
                keywords.append(String(format: "mean B-factor %.1f", mean))
            }
        }

        // Ligand inventory: include 3-letter codes plus full names (separately
        // indexed in keywords).
        for (code, name) in ligands {
            keywords.append(code)
            let trimmedName = collapseWhitespace(name)
            if !trimmedName.isEmpty { keywords.append(trimmedName) }
        }

        // SEQRES sequence: dump as kMDItemTextContent (Spotlight full-text indexes
        // this field). Multi-chain joined by space so token-search across chains works.
        if !seqresByChain.isEmpty {
            let joined = seqresByChain.keys.sorted()
                .map { (seqresByChain[$0] ?? "") }
                .joined(separator: " ")
            if !joined.isEmpty {
                a.textContent = joined
            }
        }

        keywords.append(contentsOf: organisms)
        if !keywords.isEmpty    { a.keywords = uniquePreservingOrder(keywords) }
        if !authors.isEmpty     { a.authors  = uniquePreservingOrder(authors)  }
        if let d = depositDate  { a.contentCreationDate = d }
        a.kind = "Protein Data Bank file"
    }

    // MARK: - PDB helpers

    private func lastNumericToken(_ s: String) -> Double? {
        let tokens = s.split(whereSeparator: { $0.isWhitespace || $0 == ":" })
        for token in tokens.reversed() {
            if let v = Double(token) { return v }
        }
        return nil
    }

    private func formatRValue(_ v: Double) -> String {
        return String(format: "%.3f", v)
    }

    /// 3-letter → 1-letter amino acid code. Falls back to "X" for unknown residues
    /// (DNA/RNA/modified residues) so Spotlight still has a sequence token.
    private func threeLetterToOne(_ code: String) -> String {
        switch code.uppercased() {
        case "ALA": return "A"
        case "ARG": return "R"
        case "ASN": return "N"
        case "ASP": return "D"
        case "CYS": return "C"
        case "GLU": return "E"
        case "GLN": return "Q"
        case "GLY": return "G"
        case "HIS": return "H"
        case "ILE": return "I"
        case "LEU": return "L"
        case "LYS": return "K"
        case "MET": return "M"
        case "PHE": return "F"
        case "PRO": return "P"
        case "SER": return "S"
        case "THR": return "T"
        case "TRP": return "W"
        case "TYR": return "Y"
        case "VAL": return "V"
        // Nucleic acids: emit lowercase to remain searchable but visually distinct.
        case "A", "DA": return "a"
        case "C", "DC": return "c"
        case "G", "DG": return "g"
        case "T", "DT": return "t"
        case "U":       return "u"
        default:        return "X"
        }
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
        // R-free / R-work (mmCIF)
        if let rf = scanCIFValue(lines, key: "_refine.ls_R_factor_R_free"),
           let v = Double(rf), v > 0 && v < 1 {
            keywords.append("R-free \(formatRValue(v))")
        }
        if let rw = scanCIFValue(lines, key: "_refine.ls_R_factor_R_work"),
           let v = Double(rw), v > 0 && v < 1 {
            keywords.append("R-work \(formatRValue(v))")
        }
        // Sequence: _entity_poly.pdbx_seq_one_letter_code (or _can equivalent).
        // mmCIF wraps long sequences across multi-line ;-blocks; scanCIFValue
        // already concatenates those.
        if let seq = scanCIFValue(lines, key: "_entity_poly.pdbx_seq_one_letter_code_can")
                  ?? scanCIFValue(lines, key: "_entity_poly.pdbx_seq_one_letter_code") {
            // CIF inserts "\n" and parentheses (modified residues); strip both.
            let clean = seq
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
            if !clean.isEmpty { a.textContent = clean }
        }
        // Ligands from chem_comp loop (3-letter id + name columns).
        if let codes = scanCIFLoopColumn(lines, key: "_chem_comp.id"),
           let names = scanCIFLoopColumn(lines, key: "_chem_comp.name") {
            for (i, code) in codes.enumerated() {
                let upper = code.uppercased()
                if upper == "HOH" || upper == "WAT" || upper == "DOD" { continue }
                keywords.append(upper)
                if i < names.count { keywords.append(names[i]) }
            }
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
