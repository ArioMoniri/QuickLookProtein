//
//  SharedFunctions.swift
//  QuickLookProtein
//
//  Created by Jethro Hemmann on 22.08.21.
//

import Foundation
import SwiftUI

/// Bundle of viewer options resolved once from `SettingsStorage` and passed to `prepare3DmolHTML`.
struct ViewerOptions {
    var atomStyle: Settings.AtomStyle
    var colorScheme: Settings.ColorScheme
    var rotationSpeed: Settings.RotationSpeed
    var bgColor: Color
    var autoStyleHetero: Bool
    var showSurface: Bool
    var hideHydrogens: Bool
    var showUnitCell: Bool
    var showInfoOverlay: Bool
    var defaultZoom: Settings.DefaultZoom
    var fileName: String

    // Info-overlay field toggles (1.7.19+). All read from
    // SettingsStorage so a change in the Settings UI propagates to
    // the next preview without a relaunch.
    var infoShowFileName:         Bool
    var infoShowAtomCount:        Bool
    var infoShowChainCount:       Bool
    var infoShowFormat:           Bool
    var infoShowResidueCount:     Bool
    var infoShowElementBreakdown: Bool
    var infoShowMolWeight:        Bool
    var infoShowBondCount:        Bool
    var infoShowPDBTitle:         Bool

    // Interactive 3Dmol toolbar (1.7.27+).
    var showControlsInPreview:    Bool

    // 8 per-button visibility flags + outline shading (1.7.29+).
    var ctlShowStick:    Bool
    var ctlShowLine:     Bool
    var ctlShowSphere:   Bool
    var ctlShowCartoon:  Bool
    var ctlShowSurface:  Bool
    var ctlShowColorSS:  Bool
    var ctlShowLabelCA:  Bool
    var ctlShowRecenter: Bool
    var outlineShading:  Bool
    var autoOrient:      Bool
    var cubeIsosurface:  Bool

    static func from(_ s: SettingsStorage, fileExtension ext: String, fileName: String) -> ViewerOptions {
        ViewerOptions(
            atomStyle:       s.atomStyle(forExtension: ext),
            colorScheme:     s.colorScheme,
            rotationSpeed:   s.rotationSpeed,
            bgColor:         s.bgColor,
            autoStyleHetero: s.autoStyleHetero,
            showSurface:     s.showSurface,
            hideHydrogens:   s.hideHydrogens,
            showUnitCell:    s.showUnitCell,
            showInfoOverlay: s.showInfoOverlay,
            defaultZoom:     s.defaultZoom,
            fileName:        fileName,
            infoShowFileName:         s.infoShowFileName,
            infoShowAtomCount:        s.infoShowAtomCount,
            infoShowChainCount:       s.infoShowChainCount,
            infoShowFormat:           s.infoShowFormat,
            infoShowResidueCount:     s.infoShowResidueCount,
            infoShowElementBreakdown: s.infoShowElementBreakdown,
            infoShowMolWeight:        s.infoShowMolWeight,
            infoShowBondCount:        s.infoShowBondCount,
            infoShowPDBTitle:         s.infoShowPDBTitle,
            showControlsInPreview:    s.showControlsInPreview,
            ctlShowStick:    s.ctlShowStick,
            ctlShowLine:     s.ctlShowLine,
            ctlShowSphere:   s.ctlShowSphere,
            ctlShowCartoon:  s.ctlShowCartoon,
            ctlShowSurface:  s.ctlShowSurface,
            ctlShowColorSS:  s.ctlShowColorSS,
            ctlShowLabelCA:  s.ctlShowLabelCA,
            ctlShowRecenter: s.ctlShowRecenter,
            outlineShading:  s.outlineShading,
            autoOrient:      s.autoOrient,
            cubeIsosurface:  s.cubeIsosurface
        )
    }
}

// MARK: - Computational-chemistry output parsers (1.7.30+)
//
// Gaussian (.gjf input / .log + .out output), ORCA (.out), and
// QChem (.out) produce well-defined Cartesian coordinate blocks
// in their output text. We pre-parse the file in Swift, turn the
// last optimization step into an XYZ-format string, and hand that
// to 3Dmol which already knows how to render XYZ. This is much
// simpler than writing a 3Dmol-side parser per format and lets us
// reuse the existing distance-based bond perception.

/// Try every computational-chem output parser in turn. Returns
/// (xyzText, format="xyz") on success, nil on no match.
internal func parseComputationalChem(_ raw: String, extension ext: String) -> (xyz: String, originalExt: String)? {
    let head = String(raw.prefix(8192))
    // ORCA: header line "* O   R   C   A *" appears within the first few KB.
    if head.contains("* O   R   C   A *") || head.contains("ORCA terminated") {
        if let xyz = parseOrcaOutput(raw) { return (xyz, ext) }
    }
    // Gaussian: "Gaussian, Inc." in the header, or "Standard orientation"
    // / "Input orientation" blocks.
    if head.contains("Gaussian, Inc.") || head.contains("Entering Link 1") || raw.contains("Standard orientation:") {
        if let xyz = parseGaussianOutput(raw) { return (xyz, ext) }
    }
    // QChem: "Q-Chem" banner.
    if head.contains("A Quantum Leap Into The Future Of Chemistry") || head.contains("Welcome to Q-Chem") {
        if let xyz = parseQChemOutput(raw) { return (xyz, ext) }
    }
    // Gaussian input (.gjf / .com): blank-separated sections, atoms in
    // a "C  x  y  z" block.
    if ext == "gjf" || ext == "com" {
        if let xyz = parseGaussianInput(raw) { return (xyz, ext) }
    }
    return nil
}

/// ORCA output: scan for "CARTESIAN COORDINATES (ANGSTROEM)" blocks.
/// Each block starts with that header, then a separator line, then
/// `<element>  x  y  z` rows. Use the LAST block found (= final
/// optimized geometry).
private func parseOrcaOutput(_ raw: String) -> String? {
    let marker = "CARTESIAN COORDINATES (ANGSTROEM)"
    var lastBlockStart: String.Index? = nil
    var searchStart = raw.startIndex
    while let r = raw.range(of: marker, range: searchStart..<raw.endIndex) {
        lastBlockStart = r.upperBound
        searchStart = r.upperBound
    }
    guard let start = lastBlockStart else { return nil }
    let lines = raw[start...].split(separator: "\n", maxSplits: 4096, omittingEmptySubsequences: false)
    var atoms: [(elem: String, x: String, y: String, z: String)] = []
    var sawDataLine = false
    for line in lines {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            if sawDataLine { break }
            continue
        }
        if t.hasPrefix("---") { continue }
        let parts = t.split(separator: " ", maxSplits: 16, omittingEmptySubsequences: true)
        if parts.count < 4 { break }
        if Double(parts[1]) == nil || Double(parts[2]) == nil || Double(parts[3]) == nil { break }
        atoms.append((String(parts[0]), String(parts[1]), String(parts[2]), String(parts[3])))
        sawDataLine = true
    }
    return atoms.isEmpty ? nil : buildXYZ(comment: "ORCA - final geometry", atoms: atoms)
}

/// Gaussian output: "Standard orientation:" or "Input orientation:"
/// table. Format:
///   Center  Atomic   Atomic   Coordinates
///   Number  Number   Type     X    Y    Z
///   ---
///   1       6        0        0.0  0.0  0.0
///   ...
/// Use the LAST such block (final optimization step).
private func parseGaussianOutput(_ raw: String) -> String? {
    let markers = ["Standard orientation:", "Input orientation:"]
    var lastBlockStart: String.Index? = nil
    for marker in markers {
        var searchStart = raw.startIndex
        while let r = raw.range(of: marker, range: searchStart..<raw.endIndex) {
            lastBlockStart = r.upperBound
            searchStart = r.upperBound
        }
    }
    guard let start = lastBlockStart else { return nil }
    let lines = raw[start...].split(separator: "\n", maxSplits: 8192, omittingEmptySubsequences: false)
    var atoms: [(elem: String, x: String, y: String, z: String)] = []
    var dashCount = 0
    var inDataRows = false
    for line in lines {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("---") {
            dashCount += 1
            if dashCount == 2 { inDataRows = true; continue }
            if dashCount >= 3 { break }   // end of the block
            continue
        }
        if !inDataRows { continue }
        let parts = t.split(separator: " ", maxSplits: 16, omittingEmptySubsequences: true)
        if parts.count < 6 { continue }
        guard let z   = Int(parts[1]),  // atomic number
              let xv  = Double(parts[3]),
              let yv  = Double(parts[4]),
              let zv  = Double(parts[5])
        else { continue }
        let element = atomicNumberToElement(z)
        atoms.append((element,
                      String(format: "%.6f", xv),
                      String(format: "%.6f", yv),
                      String(format: "%.6f", zv)))
    }
    return atoms.isEmpty ? nil : buildXYZ(comment: "Gaussian - last geometry", atoms: atoms)
}

/// QChem output: "Standard Nuclear Orientation (Angstroms)" table.
/// Format is similar to Gaussian but with element symbols rather
/// than atomic numbers.
private func parseQChemOutput(_ raw: String) -> String? {
    let marker = "Standard Nuclear Orientation (Angstroms)"
    var lastBlockStart: String.Index? = nil
    var searchStart = raw.startIndex
    while let r = raw.range(of: marker, range: searchStart..<raw.endIndex) {
        lastBlockStart = r.upperBound
        searchStart = r.upperBound
    }
    guard let start = lastBlockStart else { return nil }
    let lines = raw[start...].split(separator: "\n", maxSplits: 8192, omittingEmptySubsequences: false)
    var atoms: [(elem: String, x: String, y: String, z: String)] = []
    var dashCount = 0
    var inDataRows = false
    for line in lines {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("---") {
            dashCount += 1
            if dashCount == 1 { inDataRows = true; continue }
            if dashCount >= 2 { break }
            continue
        }
        if !inDataRows { continue }
        let parts = t.split(separator: " ", maxSplits: 16, omittingEmptySubsequences: true)
        if parts.count < 5 { continue }
        if Double(parts[2]) == nil || Double(parts[3]) == nil || Double(parts[4]) == nil { continue }
        atoms.append((String(parts[1]), String(parts[2]), String(parts[3]), String(parts[4])))
    }
    return atoms.isEmpty ? nil : buildXYZ(comment: "QChem - final geometry", atoms: atoms)
}

/// Gaussian input file (.gjf / .com): a small text file with title +
/// blank lines + charge/multiplicity line + atom block. Find the
/// charge/mult line (two integers) and read the atom rows after it.
private func parseGaussianInput(_ raw: String) -> String? {
    let lines = raw.split(separator: "\n", maxSplits: 2048, omittingEmptySubsequences: false)
    var inAtoms = false
    var atoms: [(elem: String, x: String, y: String, z: String)] = []
    for line in lines {
        let t = line.trimmingCharacters(in: .whitespaces)
        if !inAtoms {
            // Two-integer line marks charge + multiplicity, atom block
            // starts on the next line.
            let parts = t.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, Int(parts[0]) != nil, Int(parts[1]) != nil {
                inAtoms = true
                continue
            }
            continue
        }
        if t.isEmpty { break }
        let parts = t.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count < 4 { break }
        guard Double(parts[1]) != nil, Double(parts[2]) != nil, Double(parts[3]) != nil else { break }
        atoms.append((String(parts[0]),
                      String(parts[1]), String(parts[2]), String(parts[3])))
    }
    return atoms.isEmpty ? nil : buildXYZ(comment: "Gaussian input", atoms: atoms)
}

/// Build a standard XMol XYZ string from a list of atom tuples.
private func buildXYZ(comment: String, atoms: [(elem: String, x: String, y: String, z: String)]) -> String {
    var s = "\(atoms.count)\n"
    s += "\(comment)\n"
    for a in atoms {
        s += "\(a.elem) \(a.x) \(a.y) \(a.z)\n"
    }
    return s
}

/// Periodic-table lookup for the first 86 elements. Used by the
/// Gaussian-output parser (it reports atomic numbers, not symbols).
private func atomicNumberToElement(_ z: Int) -> String {
    let table = [
        "H","He","Li","Be","B","C","N","O","F","Ne",
        "Na","Mg","Al","Si","P","S","Cl","Ar","K","Ca",
        "Sc","Ti","V","Cr","Mn","Fe","Co","Ni","Cu","Zn",
        "Ga","Ge","As","Se","Br","Kr","Rb","Sr","Y","Zr",
        "Nb","Mo","Tc","Ru","Rh","Pd","Ag","Cd","In","Sn",
        "Sb","Te","I","Xe","Cs","Ba","La","Ce","Pr","Nd",
        "Pm","Sm","Eu","Gd","Tb","Dy","Ho","Er","Tm","Yb",
        "Lu","Hf","Ta","W","Re","Os","Ir","Pt","Au","Hg",
        "Tl","Pb","Bi","Po","At","Rn",
    ]
    if z < 1 || z > table.count { return "C" }
    return table[z - 1]
}

/// Quick-and-dirty PDB title scrape. Only walks the first ~16 KB of
/// the file (titles are always near the top); concatenates every
/// `TITLE   ` continuation record per the PDB spec. Returns nil for
/// non-PDB formats and for PDBs with no TITLE record.
func extractPDBTitle(from raw: String) -> String? {
    var lines = raw.split(separator: "\n", maxSplits: 200, omittingEmptySubsequences: false)
    if lines.count > 200 { lines = Array(lines.prefix(200)) }
    var title = ""
    for line in lines {
        if line.hasPrefix("TITLE ") {
            // PDB TITLE record: cols 11-80 are the title text.
            let s = String(line)
            if s.count >= 11 {
                let start = s.index(s.startIndex, offsetBy: 10)
                title += s[start...].trimmingCharacters(in: .whitespaces) + " "
            }
        } else if line.hasPrefix("ATOM") || line.hasPrefix("HETATM") {
            // Titles are always before atom records; bail when we hit
            // one so we don't scan the whole file.
            break
        }
    }
    let trimmed = title.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

/// Loads the bundled 3Dmol viewer HTML, injects the structure file's contents and the
/// user-selected rendering options, and returns a self-contained HTML string ready for
/// `WKWebView.loadHTMLString(_:baseURL:)`.
///
/// Injection is done via a `<script type="text/plain">` element rather than a JS template
/// literal, so the file contents cannot escape into the JS context. The only sequence we
/// need to neutralise is `</script>` itself, which is split into `<\/script>`.
func prepare3DmolHTML(htmlPath: String,
                      pdbPath: String,
                      dataFormat: String,
                      options: ViewerOptions,
                      thumbnailMode: Bool = false) -> String {
    let template: String
    do {
        template = try String(contentsOfFile: htmlPath, encoding: .utf8)
    } catch {
        return errorHTML(title: "Internal error",
                         detail: "Could not load viewer template: \(error.localizedDescription)")
    }

    // Try common text encodings explicitly — `String(contentsOfFile:)` without an
    // encoding hint will reject any file that isn't valid UTF-8, which routinely fails
    // for CIFs containing Latin-1 author names or older PDB files written on Windows.
    let rawOriginal: String
    do {
        rawOriginal = try readMolecularTextFile(pdbPath)
    } catch {
        return errorHTML(title: "Could not read file",
                         detail: error.localizedDescription)
    }

    // Computational-chem output pre-parse (1.7.30+): if the file
    // looks like a Gaussian / ORCA / QChem output (or .gjf / .com
    // input), extract the last coordinate block, rewrite it as XYZ,
    // and dispatch 3Dmol to its native XYZ parser. Falls through if
    // not a recognised compchem format.
    let raw: String
    let resolvedFormat: String
    if let conv = parseComputationalChem(rawOriginal, extension: pdbPath.lowercased().components(separatedBy: ".").last ?? "") {
        raw = conv.xyz
        resolvedFormat = "xyz"
    } else {
        raw = rawOriginal
        resolvedFormat = dataFormat
    }

    let safeData = sanitizeForScriptBlock(raw)
    let bg = convertColorToRGB(color: options.bgColor)

    // Substitution order matters: the data block must be inserted *last* so that any
    // `{...}` sequences that happen to occur inside the data aren't treated as placeholders.
    var html = template
    html = html.replacingOccurrences(of: "{ATOM_STYLE}",        with: options.atomStyle.jsValue)
    html = html.replacingOccurrences(of: "{COLOR_SCHEME}",      with: options.colorScheme.jsValue)
    html = html.replacingOccurrences(of: "{BG_COLOR}",          with: bg.rgbHex)
    html = html.replacingOccurrences(of: "{BG_ALPHA}",          with: bg.alpha)
    html = html.replacingOccurrences(of: "{ROTATION_SPEED}",    with: String(options.rotationSpeed.rotationSpeedNumber()))
    html = html.replacingOccurrences(of: "{DATA_FORMAT}",       with: resolvedFormat)
    html = html.replacingOccurrences(of: "{AUTO_STYLE_HETERO}", with: options.autoStyleHetero ? "true" : "false")
    html = html.replacingOccurrences(of: "{SHOW_SURFACE}",      with: options.showSurface      ? "true" : "false")
    html = html.replacingOccurrences(of: "{HIDE_H}",            with: options.hideHydrogens    ? "true" : "false")
    html = html.replacingOccurrences(of: "{SHOW_UNIT_CELL}",    with: options.showUnitCell     ? "true" : "false")
    html = html.replacingOccurrences(of: "{SHOW_INFO}",         with: options.showInfoOverlay  ? "true" : "false")
    html = html.replacingOccurrences(of: "{FILE_NAME}",         with: escapeForHTMLAttribute(options.fileName))
    // Info-overlay field toggles (1.7.19+).
    html = html.replacingOccurrences(of: "{INFO_FILE_NAME}",     with: options.infoShowFileName         ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_ATOM_COUNT}",    with: options.infoShowAtomCount        ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_CHAIN_COUNT}",   with: options.infoShowChainCount       ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_FORMAT}",        with: options.infoShowFormat           ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_RES_COUNT}",     with: options.infoShowResidueCount     ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_ELEMENT_BREAKDOWN}", with: options.infoShowElementBreakdown ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_MOL_WEIGHT}",    with: options.infoShowMolWeight        ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_BOND_COUNT}",    with: options.infoShowBondCount        ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_PDB_TITLE}",     with: options.infoShowPDBTitle         ? "true" : "false")
    html = html.replacingOccurrences(of: "{SHOW_CONTROLS}",      with: options.showControlsInPreview    ? "true" : "false")
    // Per-button toolbar visibility (1.7.29+).
    html = html.replacingOccurrences(of: "{CTL_SHOW_STICK}",    with: options.ctlShowStick    ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_LINE}",     with: options.ctlShowLine     ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_SPHERE}",   with: options.ctlShowSphere   ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_CARTOON}",  with: options.ctlShowCartoon  ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_SURFACE}",  with: options.ctlShowSurface  ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_COLORSS}",  with: options.ctlShowColorSS  ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_LABELCA}",  with: options.ctlShowLabelCA  ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_RECENTER}", with: options.ctlShowRecenter ? "true" : "false")
    html = html.replacingOccurrences(of: "{OUTLINE_SHADING}",   with: options.outlineShading  ? "true" : "false")
    html = html.replacingOccurrences(of: "{AUTO_ORIENT}",       with: options.autoOrient      ? "true" : "false")
    html = html.replacingOccurrences(of: "{CUBE_ISOSURFACE}",   with: options.cubeIsosurface  ? "true" : "false")
    // PDB TITLE record contents, if any. Always passed but only shown
    // when {INFO_PDB_TITLE} is true. Safe-escape so weird titles can't
    // break out of the JS string literal.
    let pdbTitle = extractPDBTitle(from: raw) ?? ""
    html = html.replacingOccurrences(of: "{PDB_TITLE}", with: escapeForJSStringLiteral(pdbTitle))
    html = html.replacingOccurrences(of: "{ZOOM_FACTOR}",       with: String(options.defaultZoom.factor))
    html = html.replacingOccurrences(of: "{ZOOM_IS_AUTO}",      with: options.defaultZoom == .auto ? "true" : "false")
    html = html.replacingOccurrences(of: "{THUMBNAIL_MODE}",    with: thumbnailMode ? "true" : "false")
    html = html.replacingOccurrences(of: "{MOL_DATA}",          with: safeData)
    // No extra models in the single-file path - just clear the
    // placeholder so the JS array is empty.
    html = html.replacingOccurrences(of: "{EXTRA_MODELS_JSON}",  with: "[]")
    html = html.replacingOccurrences(of: "{EXTRA_MODELS_HTML}",  with: "")
    return html
}

// MARK: - Multi-file merge mode (1.7.23+)

/// File extensions the merge-mode siblings collector considers.
/// Same set the main app & QL extension claim, minus formats whose
/// 3Dmol parser doesn't compose well in a multi-model scene (MMTF
/// is a binary container, CDJSON has its own scene semantics).
private let mergeableExtensions: Set<String> = [
    "pdb", "ent", "pdbqt", "pqr",
    "cif", "mmcif",
    "sdf", "mol", "mol2",
    "xyz", "gro", "cube", "cub",
]

/// Cap on how many sibling files to merge. Beyond this the preview
/// becomes a wall of overlapping atoms and the JS string grows huge.
private let mergeMaxFiles = 25

/// Cap on size of each sibling read - same per-preview budget the
/// QL extension uses for the primary file.
private let mergeMaxBytesPerFile = 5 * 1024 * 1024

/// Bundle handed to `prepare3DmolHTMLMulti`. Each entry is one
/// structure to layer into the combined 3Dmol scene.
struct MergeInput {
    let url: URL
    let format: String   // 3Dmol parser key ("pdb", "mol2", ...)
    let data: String     // raw text contents
}

/// Walk the directory containing `url`, return one `MergeInput` per
/// supported sibling we can actually read. Returns nil if the
/// directory enumeration itself fails (typically because the sandbox
/// only granted us access to this single file). Returns an array
/// with just the original file if nothing else is readable, so the
/// caller can still render normally.
func collectMergeSiblings(forFileAt url: URL) -> [MergeInput]? {
    let fm = FileManager.default
    let parent = url.deletingLastPathComponent()
    let contents: [URL]
    do {
        contents = try fm.contentsOfDirectory(at: parent,
                                              includingPropertiesForKeys: [.fileSizeKey],
                                              options: [.skipsHiddenFiles])
    } catch {
        // Sandbox almost certainly refused the directory listing.
        // Caller falls back to single-file rendering.
        return nil
    }
    // Always include the requested file first so it stays the "primary"
    // model and any settings driven by its extension still apply.
    var inputs: [MergeInput] = []
    if let primary = readMergeInput(at: url) {
        inputs.append(primary)
    } else {
        return nil
    }
    let primaryPath = url.standardizedFileURL.path
    for u in contents {
        if inputs.count >= mergeMaxFiles { break }
        if u.standardizedFileURL.path == primaryPath { continue }
        let ext = u.pathExtension.lowercased()
        guard mergeableExtensions.contains(ext) else { continue }
        if let attr = try? fm.attributesOfItem(atPath: u.path),
           let size = attr[.size] as? Int, size > mergeMaxBytesPerFile {
            continue
        }
        if let m = readMergeInput(at: u) { inputs.append(m) }
    }
    return inputs
}

private func readMergeInput(at url: URL) -> MergeInput? {
    let ext = url.pathExtension.lowercased()
    let format = Settings.dataFormat(forExtension: ext) ?? "pdb"
    do {
        let raw = try readMolecularTextFile(url.path)
        return MergeInput(url: url, format: format, data: raw)
    } catch {
        return nil
    }
}

/// Render the multi-model variant of the 3Dmol HTML. Embeds each
/// structure as its own `<script type="text/plain">` block and
/// emits a JS array of `{id, format, name}` records for the viewer
/// to iterate via `viewer.addModel`. The first model is the
/// "primary" file - its extension drives ATOM_STYLE / DATA_FORMAT
/// so single-file settings still apply unchanged.
func prepare3DmolHTMLMulti(htmlPath: String,
                           files: [MergeInput],
                           options: ViewerOptions) -> String {
    guard let primary = files.first else {
        return errorHTML(title: "Internal error",
                         detail: "Merge mode called with no files")
    }
    let template: String
    do {
        template = try String(contentsOfFile: htmlPath, encoding: .utf8)
    } catch {
        return errorHTML(title: "Internal error",
                         detail: "Could not load viewer template: \(error.localizedDescription)")
    }

    // Build the extra-models HTML payload: one <script type="text/plain">
    // per sibling, plus a JS array of {id, format, name} that the
    // viewer iterates after loading the primary model.
    var extraHtml = ""
    var extraRecords: [String] = []
    for (idx, file) in files.dropFirst().enumerated() {
        let blockId = "qlp-extra-\(idx)"
        let safeData = sanitizeForScriptBlock(file.data)
        extraHtml += "<script id=\"\(blockId)\" type=\"text/plain\">\n"
        extraHtml += safeData
        extraHtml += "\n</script>\n"
        let name = escapeForJSStringLiteral(file.url.lastPathComponent)
        let fmt  = escapeForJSStringLiteral(file.format)
        extraRecords.append("{id:\"\(blockId)\",format:\"\(fmt)\",name:\"\(name)\"}")
    }
    let extraJson = "[" + extraRecords.joined(separator: ",") + "]"

    // Reuse the single-file fill path for the primary structure, then
    // overwrite the multi-model placeholders.
    let dataFormat = primary.format
    let bg = convertColorToRGB(color: options.bgColor)
    let safePrimary = sanitizeForScriptBlock(primary.data)

    var html = template
    html = html.replacingOccurrences(of: "{ATOM_STYLE}",        with: options.atomStyle.jsValue)
    html = html.replacingOccurrences(of: "{COLOR_SCHEME}",      with: options.colorScheme.jsValue)
    html = html.replacingOccurrences(of: "{BG_COLOR}",          with: bg.rgbHex)
    html = html.replacingOccurrences(of: "{BG_ALPHA}",          with: bg.alpha)
    html = html.replacingOccurrences(of: "{ROTATION_SPEED}",    with: String(options.rotationSpeed.rotationSpeedNumber()))
    html = html.replacingOccurrences(of: "{DATA_FORMAT}",       with: dataFormat)
    html = html.replacingOccurrences(of: "{AUTO_STYLE_HETERO}", with: options.autoStyleHetero ? "true" : "false")
    html = html.replacingOccurrences(of: "{SHOW_SURFACE}",      with: options.showSurface      ? "true" : "false")
    html = html.replacingOccurrences(of: "{HIDE_H}",            with: options.hideHydrogens    ? "true" : "false")
    html = html.replacingOccurrences(of: "{SHOW_UNIT_CELL}",    with: options.showUnitCell     ? "true" : "false")
    html = html.replacingOccurrences(of: "{SHOW_INFO}",         with: options.showInfoOverlay  ? "true" : "false")
    let bigName = "\(primary.url.lastPathComponent) (+\(files.count - 1) merged)"
    html = html.replacingOccurrences(of: "{FILE_NAME}",         with: escapeForHTMLAttribute(bigName))
    html = html.replacingOccurrences(of: "{INFO_FILE_NAME}",         with: options.infoShowFileName         ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_ATOM_COUNT}",        with: options.infoShowAtomCount        ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_CHAIN_COUNT}",       with: options.infoShowChainCount       ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_FORMAT}",            with: options.infoShowFormat           ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_RES_COUNT}",         with: options.infoShowResidueCount     ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_ELEMENT_BREAKDOWN}", with: options.infoShowElementBreakdown ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_MOL_WEIGHT}",        with: options.infoShowMolWeight        ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_BOND_COUNT}",        with: options.infoShowBondCount        ? "true" : "false")
    html = html.replacingOccurrences(of: "{INFO_PDB_TITLE}",         with: options.infoShowPDBTitle         ? "true" : "false")
    html = html.replacingOccurrences(of: "{SHOW_CONTROLS}",          with: options.showControlsInPreview    ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_STICK}",         with: options.ctlShowStick    ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_LINE}",          with: options.ctlShowLine     ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_SPHERE}",        with: options.ctlShowSphere   ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_CARTOON}",       with: options.ctlShowCartoon  ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_SURFACE}",       with: options.ctlShowSurface  ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_COLORSS}",       with: options.ctlShowColorSS  ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_LABELCA}",       with: options.ctlShowLabelCA  ? "true" : "false")
    html = html.replacingOccurrences(of: "{CTL_SHOW_RECENTER}",      with: options.ctlShowRecenter ? "true" : "false")
    html = html.replacingOccurrences(of: "{OUTLINE_SHADING}",        with: options.outlineShading  ? "true" : "false")
    html = html.replacingOccurrences(of: "{AUTO_ORIENT}",            with: options.autoOrient      ? "true" : "false")
    html = html.replacingOccurrences(of: "{CUBE_ISOSURFACE}",        with: options.cubeIsosurface  ? "true" : "false")
    let pdbTitle = extractPDBTitle(from: primary.data) ?? ""
    html = html.replacingOccurrences(of: "{PDB_TITLE}", with: escapeForJSStringLiteral(pdbTitle))
    html = html.replacingOccurrences(of: "{ZOOM_FACTOR}",       with: String(options.defaultZoom.factor))
    html = html.replacingOccurrences(of: "{ZOOM_IS_AUTO}",      with: options.defaultZoom == .auto ? "true" : "false")
    html = html.replacingOccurrences(of: "{THUMBNAIL_MODE}",    with: "false")
    html = html.replacingOccurrences(of: "{MOL_DATA}",          with: safePrimary)
    html = html.replacingOccurrences(of: "{EXTRA_MODELS_JSON}", with: extraJson)
    html = html.replacingOccurrences(of: "{EXTRA_MODELS_HTML}", with: extraHtml)
    return html
}

/// Neutralises the only sequence that can terminate a `<script type="text/plain">` element.
/// NUL bytes are stripped (some WebKit code paths truncate on NUL) and a leading UTF-8 BOM
/// is removed because 3Dmol's text parsers don't recognise it.
private func sanitizeForScriptBlock(_ s: String) -> String {
    var out = s
    if out.hasPrefix("\u{FEFF}") { out.removeFirst() }
    out = out.replacingOccurrences(of: "\u{0000}", with: "")
    out = out.replacingOccurrences(of: "</script",
                                   with: "<\\/script",
                                   options: .caseInsensitive)
    out = out.replacingOccurrences(of: "<!--", with: "<\\!--")
    out = out.replacingOccurrences(of: "-->",  with: "--\\>")
    // Replace literal `{...}` sequences that match placeholder syntax so a hostile file
    // can't smuggle a placeholder that later substitutions would expand. Since the data
    // block is inserted last via `replacingOccurrences(of: "{MOL_DATA}", ...)`, the only
    // way a placeholder in the data could matter is if a later substitution were added —
    // defense in depth.
    return out
}

/// Filename appears as a JS string literal (and could appear in HTML text). We strip
/// quotes, backslashes, angle brackets, control chars, AND curly braces — the latter so
/// a crafted filename can't introduce a placeholder that the substitution loop would
/// expand a second time.
private func escapeForHTMLAttribute(_ s: String) -> String {
    var out = s
    out = out.replacingOccurrences(of: "\\", with: "\\\\")
    out = out.replacingOccurrences(of: "\"", with: "\\\"")
    out = out.replacingOccurrences(of: "'",  with: "\\'")
    out = out.replacingOccurrences(of: "<",  with: "&lt;")
    out = out.replacingOccurrences(of: ">",  with: "&gt;")
    out = out.replacingOccurrences(of: "{",  with: "&#123;")
    out = out.replacingOccurrences(of: "}",  with: "&#125;")
    out = out.replacingOccurrences(of: "\n", with: " ")
    out = out.replacingOccurrences(of: "\r", with: " ")
    return out
}

/// Escape a string for use inside a JS double-quoted literal. Used
/// for the PDB title we inject as `var pdbTitle = "...";`. Same rules
/// as escapeForHTMLAttribute minus the HTML-entity bits.
internal func escapeForJSStringLiteral(_ s: String) -> String {
    var out = s
    out = out.replacingOccurrences(of: "\\", with: "\\\\")
    out = out.replacingOccurrences(of: "\"", with: "\\\"")
    out = out.replacingOccurrences(of: "\n", with: " ")
    out = out.replacingOccurrences(of: "\r", with: " ")
    out = out.replacingOccurrences(of: "{",  with: "\\u007b")
    out = out.replacingOccurrences(of: "}",  with: "\\u007d")
    return out
}

/// Reads a molecular text file trying common encodings before giving up. PDB / CIF /
/// MOL2 etc. are ASCII by spec but real-world files routinely contain Latin-1 in author
/// names or annotation lines, which a strict UTF-8 read would reject.
private func readMolecularTextFile(_ path: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    if let s = String(data: data, encoding: .utf8) { return s }
    if let s = String(data: data, encoding: .isoLatin1) { return s }
    if let s = String(data: data, encoding: .macOSRoman) { return s }
    throw NSError(domain: "QuickLookProtein", code: 2,
                  userInfo: [NSLocalizedDescriptionKey:
                                "File is not text in any common encoding"])
}

/// Renders a styled in-page message when the file is too large to safely render inside
/// a Quick Look extension's memory budget.
func oversizedFileHTML(name: String, sizeMB: Double) -> String {
    let safeName = name
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    let mb = String(format: "%.1f", sizeMB)
    return """
    <!doctype html><html><head><meta charset="utf-8"><style>
    html,body{margin:0;padding:0;height:100%;
      font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;
      display:flex;align-items:center;justify-content:center;
      background:transparent;color:#555;text-align:center;padding:24px;}
    .t{font-weight:600;margin-bottom:8px;font-size:14px;color:#333;}
    .d{font-size:12px;color:#777;max-width:380px;line-height:1.5;}
    @media (prefers-color-scheme: dark){
      .t{color:#eee;} .d{color:#aaa;} body{color:#ccc;}
    }
    </style></head><body><div>
      <div class="t">File too large for Quick Look preview</div>
      <div class="d">\(safeName) is \(mb) MB. Open it in a dedicated molecular viewer (e.g. PyMOL, ChimeraX) for the full structure.</div>
    </div></body></html>
    """
}

/// Renders a self-contained error page so the user sees something useful when the
/// template or input file can't be loaded.
private func errorHTML(title: String, detail: String) -> String {
    let safeTitle = title
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    let safeDetail = detail
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    return """
    <!doctype html><html><head><meta charset="utf-8"><style>
    html,body{margin:0;padding:0;height:100%;
      font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;
      display:flex;align-items:center;justify-content:center;
      background:transparent;color:#b00;text-align:center;padding:24px;}
    .t{font-weight:600;margin-bottom:6px;color:#800;}
    @media (prefers-color-scheme: dark){body{color:#ff8a8a;}.t{color:#ffb0b0;}}
    </style></head><body><div><div class="t">\(safeTitle)</div><div>\(safeDetail)</div></div></body></html>
    """
}

// https://gist.github.com/gobijan/d724de27e2aff8131676
func convertColorToRGB(color: Color) -> (rgbHex: String, alpha: String) {
    let nsColor: NSColor = NSColor(color)

    // Convert to CIColor to prevent crash when using colors of a different color space
    // https://stackoverflow.com/questions/15682923/convert-nscolor-to-rgb
    let ciColor: CIColor = CIColor(color: nsColor) ?? CIColor(red: 0, green: 0, blue: 0, alpha: 0)

    let rInt = Int((ciColor.red   * 255.99999))
    let gInt = Int((ciColor.green * 255.99999))
    let bInt = Int((ciColor.blue  * 255.99999))

    let alpha = ciColor.alpha

    let rHex = String(format: "%02X", rInt)
    let gHex = String(format: "%02X", gInt)
    let bHex = String(format: "%02X", bInt)

    return (rHex + gHex + bHex, "\(alpha)")
}
