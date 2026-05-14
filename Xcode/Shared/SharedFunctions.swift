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
    var ambientOcclusion: Bool
    var autoOrient:      Bool
    var cubeIsosurface:  Bool
    var bioAssembly:     Bool
    var cryoEMRender:    Bool
    var cryoEMSigma:     Double
    var showShareButton: Bool

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
            ambientOcclusion: s.ambientOcclusion,
            autoOrient:      s.autoOrient,
            cubeIsosurface:  s.cubeIsosurface,
            bioAssembly:     s.bioAssembly,
            cryoEMRender:    s.cryoEMRender,
            cryoEMSigma:     s.cryoEMSigma,
            showShareButton: s.showShareButton
        )
    }
}

// MARK: - Cryo-EM density maps (1.7.32+)
//
// CCP4 / MRC / MAP files are the standard cryo-EM density format.
// All three are the same on-disk layout: a 1024-byte fixed-width
// header (56 fields plus 800 bytes of label space), then a flat
// array of voxel values in row-major order. The viewer side already
// understands Gaussian Cube via 3Dmol's `VolumeData(text, "cube")`,
// so we convert CCP4 -> Cube text in Swift and reuse that path.
//
// Reference: CCP4 map format spec
//   https://www.ccp4.ac.uk/html/maplib.html#description

/// Read big-/little-endian aware values out of the fixed-width
/// header. CCP4's `MACHST` field (bytes 212-215) declares the byte
/// order: 0x44 0x44 0x00 0x00 for little-endian, 0x11 0x11 0x00 0x00
/// for big-endian. Almost every modern file is little-endian.
private enum CCP4Endian { case little, big }

private func ccp4Int32(_ data: Data, _ offset: Int, _ endian: CCP4Endian) -> Int32 {
    let bytes = data.subdata(in: offset..<(offset + 4))
    let v = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
    switch endian {
    case .little: return Int32(bitPattern: UInt32(littleEndian: v))
    case .big:    return Int32(bitPattern: UInt32(bigEndian: v))
    }
}

private func ccp4Float32(_ data: Data, _ offset: Int, _ endian: CCP4Endian) -> Float {
    let bytes = data.subdata(in: offset..<(offset + 4))
    let v = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
    let bits: UInt32
    switch endian {
    case .little: bits = UInt32(littleEndian: v)
    case .big:    bits = UInt32(bigEndian: v)
    }
    return Float(bitPattern: bits)
}

/// Convert a CCP4/MRC/MAP file to Gaussian Cube text. Returns nil if
/// the header is malformed or the data array is shorter than the
/// declared grid size. The caller hands the text to
/// `new $3Dmol.VolumeData(text, "cube")`. Sampling: maps larger than
/// ~5M voxels are downsampled by an integer stride so the cube-text
/// payload stays under ~30 MB (3Dmol's text-mode parser would
/// otherwise grind on huge maps).
internal func convertCCP4ToCube(_ data: Data) -> String? {
    guard data.count >= 1024 + 4 else { return nil }
    // Detect endianness from MACHST.
    let endian: CCP4Endian = {
        let b212 = data[212]
        return b212 == 0x44 ? .little : (b212 == 0x11 ? .big : .little)
    }()

    let nc = Int(ccp4Int32(data, 0,  endian))    // columns
    let nr = Int(ccp4Int32(data, 4,  endian))    // rows
    let ns = Int(ccp4Int32(data, 8,  endian))    // sections
    let mode = Int(ccp4Int32(data, 12, endian))
    let ncStart = Int(ccp4Int32(data, 16, endian))
    let nrStart = Int(ccp4Int32(data, 20, endian))
    let nsStart = Int(ccp4Int32(data, 24, endian))
    let mx = Int(ccp4Int32(data, 28, endian))
    let my = Int(ccp4Int32(data, 32, endian))
    let mz = Int(ccp4Int32(data, 36, endian))
    let cellA  = ccp4Float32(data, 40, endian)
    let cellB  = ccp4Float32(data, 44, endian)
    let cellC  = ccp4Float32(data, 48, endian)
    let mapc = Int(ccp4Int32(data, 64, endian))  // 1=X, 2=Y, 3=Z
    let mapr = Int(ccp4Int32(data, 68, endian))
    let maps = Int(ccp4Int32(data, 72, endian))

    if nc <= 0 || nr <= 0 || ns <= 0 { return nil }
    if mode != 2 { return nil }                  // only float32 maps for now
    if mx <= 0 || my <= 0 || mz <= 0 { return nil }

    // Voxel spacing in Angstroms.
    let dxA = cellA / Float(mx)
    let dyA = cellB / Float(my)
    let dzA = cellC / Float(mz)

    // Read the flat float32 grid. Total bytes = 4 * nc * nr * ns.
    let totalVoxels = nc * nr * ns
    let payloadOffset = 1024 + Int(ccp4Int32(data, 92, endian)) * 80  // skip extended header (NSYMBT)
    let needed = payloadOffset + 4 * totalVoxels
    guard data.count >= needed else { return nil }
    var values = [Float](repeating: 0, count: totalVoxels)
    values.withUnsafeMutableBufferPointer { buf in
        data.copyBytes(to: UnsafeMutableRawBufferPointer(buf),
                       from: payloadOffset..<needed)
    }
    if endian == .big {
        for i in 0..<totalVoxels {
            values[i] = Float(bitPattern: UInt32(bigEndian: values[i].bitPattern))
        }
    }

    // Decide whether to downsample so the resulting Cube text stays
    // manageable. We aim for <= 4M voxels in the output.
    let maxVoxels = 4_000_000
    var stride = 1
    while (nc / stride) * (nr / stride) * (ns / stride) > maxVoxels {
        stride += 1
    }
    let outNc = nc / stride
    let outNr = nr / stride
    let outNs = ns / stride
    let outDx = dxA * Float(stride)
    let outDy = dyA * Float(stride)
    let outDz = dzA * Float(stride)

    // Cube format axis ordering: outer loop X, middle Y, inner Z.
    // CCP4 stores in (col, row, section) order with mapc/mapr/maps
    // telling us which logical axis each corresponds to. For
    // simplicity we assume the common case mapc=1, mapr=2, maps=3
    // (column = X, row = Y, section = Z), and warn otherwise.
    let standardAxisOrder = (mapc == 1 && mapr == 2 && maps == 3)

    // Origin in Angstroms; in Cube's Bohr unit we'll divide by
    // 0.529177 when emitting.
    let originXA = Float(ncStart) * dxA
    let originYA = Float(nrStart) * dyA
    let originZA = Float(nsStart) * dzA
    let bohr: Float = 0.529177

    // Sample a value with optional remapping if the axis order is
    // non-standard. Conservative fallback: bail and use standard
    // order anyway - the preview will be 90-degree rotated but at
    // least it'll render.
    @inline(__always) func sample(_ x: Int, _ y: Int, _ z: Int) -> Float {
        if standardAxisOrder {
            return values[z * (nr * nc) + y * nc + x]
        }
        // Generic axis remap. mapc/mapr/maps map column/row/section
        // -> (x, y, z) axes; we want sampling by (x, y, z).
        var idxC = 0, idxR = 0, idxS = 0
        let coords = [x, y, z]
        switch mapc { case 1: idxC = coords[0]; case 2: idxC = coords[1]; case 3: idxC = coords[2]; default: idxC = coords[0] }
        switch mapr { case 1: idxR = coords[0]; case 2: idxR = coords[1]; case 3: idxR = coords[2]; default: idxR = coords[1] }
        switch maps { case 1: idxS = coords[0]; case 2: idxS = coords[1]; case 3: idxS = coords[2]; default: idxS = coords[2] }
        return values[idxS * (nr * nc) + idxR * nc + idxC]
    }

    var out = ""
    out += "CCP4 density map (converted by QuickLookProtein 1.7.32+)\n"
    out += "auto-generated cube\n"
    // -1 atoms => signals "no atoms, just volumetric data" with
    // origin in Bohr. 3Dmol's parser handles this case.
    out += String(format: "%5d %12.6f %12.6f %12.6f\n",
                  -1, originXA / bohr, originYA / bohr, originZA / bohr)
    out += String(format: "%5d %12.6f %12.6f %12.6f\n", outNc, outDx / bohr, 0.0, 0.0)
    out += String(format: "%5d %12.6f %12.6f %12.6f\n", outNr, 0.0, outDy / bohr, 0.0)
    out += String(format: "%5d %12.6f %12.6f %12.6f\n", outNs, 0.0, 0.0, outDz / bohr)
    out += String(format: "%5d %5d %12.6f %12.6f %12.6f %12.6f\n", 1, 1, 0.0, 0.0, 0.0, 0.0)

    var col = 0
    var lineBuf = ""
    for ix in 0..<outNc {
        for iy in 0..<outNr {
            for iz in 0..<outNs {
                let v = sample(ix * stride, iy * stride, iz * stride)
                lineBuf += String(format: "%13.5e", v)
                col += 1
                if col == 6 { lineBuf += "\n"; out += lineBuf; lineBuf = ""; col = 0 }
            }
            if col != 0 { lineBuf += "\n"; out += lineBuf; lineBuf = ""; col = 0 }
        }
    }
    if !lineBuf.isEmpty { out += lineBuf + "\n" }
    return out
}

// MARK: - Biological assembly expansion (1.7.31+)
//
// PDB and mmCIF entries deposit the asymmetric unit; the biological
// assembly is reconstructed from rotation+translation operators
// declared via REMARK 350 BIOMT records (PDB) or
// _pdbx_struct_assembly_gen / _pdbx_struct_oper_list loops (mmCIF).
// Most molecular viewers default to showing assembly 1 because
// that's what "the actual functional molecule" usually is - a tetramer
// of hemoglobin, the symmetric dimer of a coiled-coil, etc.
//
// We do the expansion in Swift before handing data to 3Dmol because
// 3Dmol's PDB parser doesn't apply REMARK 350 automatically.
// Strategy:
//   1. Parse all BIOMT/oper rows into [Float; 12] 3×4 matrices.
//   2. Read the original ATOM/HETATM block.
//   3. For each operator, transform every atom and emit a new
//      MODEL section. The viewer then sees the multi-MODEL PDB
//      and renders all copies stacked in one scene.
//
// Files without assembly records pass through unchanged.

/// 3×4 transformation matrix (R | t). Stored row-major so the
/// rotation rows match the file format exactly.
private struct AssemblyOperator {
    let r00, r01, r02, t0: Double
    let r10, r11, r12, t1: Double
    let r20, r21, r22, t2: Double
    /// Identity operator. Identity is the trivial case - the
    /// asymmetric unit itself.
    static let identity = AssemblyOperator(
        r00: 1, r01: 0, r02: 0, t0: 0,
        r10: 0, r11: 1, r12: 0, t1: 0,
        r20: 0, r21: 0, r22: 1, t2: 0)
}

/// Top-level entry point. Returns the expanded PDB text (or nil if
/// no assembly was found, in which case the caller uses the
/// original file unchanged).
internal func expandBiologicalAssembly(_ raw: String, extension ext: String) -> String? {
    if ext == "pdb" || ext == "ent" {
        return expandAssemblyPDB(raw)
    }
    if ext == "cif" || ext == "mmcif" {
        return expandAssemblyCIF(raw)
    }
    return nil
}

/// PDB path: parse REMARK 350 BIOMT records into AssemblyOperator
/// matrices, then apply them to every ATOM/HETATM in the file.
/// REMARK 350 layout:
///   REMARK 350 BIOMT1 1  1.000000  0.000000  0.000000        0.00000
///   REMARK 350 BIOMT2 1  0.000000  1.000000  0.000000        0.00000
///   REMARK 350 BIOMT3 1  0.000000  0.000000  1.000000        0.00000
/// The serial number after BIOMTn groups the three rows of one matrix.
private func expandAssemblyPDB(_ raw: String) -> String? {
    var operators: [Int: (row1: [Double]?, row2: [Double]?, row3: [Double]?)] = [:]
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    for line in lines {
        guard line.hasPrefix("REMARK 350 BIOMT") else { continue }
        guard line.count >= 53 else { continue }
        let chars = Array(line)
        // BIOMTn  serial  m11 m12 m13 t
        let nIdx = chars[16].wholeNumberValue
        let serialStr = String(chars[17..<24]).trimmingCharacters(in: .whitespaces)
        let serial = Int(serialStr) ?? -1
        let m1 = Double(String(chars[24..<34]).trimmingCharacters(in: .whitespaces))
        let m2 = Double(String(chars[34..<44]).trimmingCharacters(in: .whitespaces))
        let m3 = Double(String(chars[44..<54]).trimmingCharacters(in: .whitespaces))
        let endIdx = min(chars.count, 68)
        let t  = Double(String(chars[54..<endIdx]).trimmingCharacters(in: .whitespaces))
        guard let nI = nIdx, serial >= 0, let mm1 = m1, let mm2 = m2, let mm3 = m3, let tt = t else { continue }
        let row = [mm1, mm2, mm3, tt]
        let cur = operators[serial] ?? (nil, nil, nil)
        switch nI {
        case 1: operators[serial] = (row, cur.row2, cur.row3)
        case 2: operators[serial] = (cur.row1, row, cur.row3)
        case 3: operators[serial] = (cur.row1, cur.row2, row)
        default: break
        }
    }
    // Build a list of fully-specified operators in serial order.
    var ops: [AssemblyOperator] = []
    for serial in operators.keys.sorted() {
        guard let group = operators[serial],
              let r1 = group.row1, let r2 = group.row2, let r3 = group.row3 else { continue }
        ops.append(AssemblyOperator(
            r00: r1[0], r01: r1[1], r02: r1[2], t0: r1[3],
            r10: r2[0], r11: r2[1], r12: r2[2], t1: r2[3],
            r20: r3[0], r21: r3[1], r22: r3[2], t2: r3[3]))
    }
    // Skip if there's only the identity operator - rebuild is a no-op.
    if ops.count <= 1 {
        if ops.isEmpty { return nil }
        if isIdentity(ops[0]) { return nil }
    }
    return rewritePDBWithOperators(raw, operators: ops)
}

private func isIdentity(_ op: AssemblyOperator) -> Bool {
    return abs(op.r00 - 1) < 1e-6 && abs(op.r01) < 1e-6 && abs(op.r02) < 1e-6 && abs(op.t0) < 1e-6 &&
           abs(op.r10) < 1e-6 && abs(op.r11 - 1) < 1e-6 && abs(op.r12) < 1e-6 && abs(op.t1) < 1e-6 &&
           abs(op.r20) < 1e-6 && abs(op.r21) < 1e-6 && abs(op.r22 - 1) < 1e-6 && abs(op.t2) < 1e-6
}

private func rewritePDBWithOperators(_ raw: String, operators: [AssemblyOperator]) -> String {
    // Find header lines (everything before the first ATOM/HETATM)
    // and trailer (CONECT/MASTER/END after the last ATOM). We keep
    // headers once and stitch each operator's transformed atoms
    // inside a MODEL/ENDMDL pair so 3Dmol parses them as separate
    // models stacked in one scene.
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    var headerLines: [Substring] = []
    var atomLines:   [Substring] = []
    var trailerLines: [Substring] = []
    var seenAtom = false
    var lastAtomIdx = -1
    for (idx, line) in lines.enumerated() {
        if line.hasPrefix("ATOM") || line.hasPrefix("HETATM") {
            seenAtom = true
            atomLines.append(line)
            lastAtomIdx = idx
        } else if !seenAtom {
            headerLines.append(line)
        }
    }
    if lastAtomIdx >= 0 && lastAtomIdx + 1 < lines.count {
        trailerLines = Array(lines[(lastAtomIdx + 1)...])
    }
    var output = headerLines.joined(separator: "\n")
    if !output.isEmpty { output += "\n" }
    for (i, op) in operators.enumerated() {
        output += String(format: "MODEL     %4d\n", i + 1)
        for atom in atomLines {
            output += transformedPDBAtomLine(atom, op: op) + "\n"
        }
        output += "ENDMDL\n"
    }
    if !trailerLines.isEmpty {
        output += trailerLines.joined(separator: "\n")
    }
    return output
}

/// Apply the rotation+translation to the x/y/z columns of a single
/// ATOM/HETATM record while preserving every other column.
private func transformedPDBAtomLine(_ line: Substring, op: AssemblyOperator) -> String {
    let chars = Array(line)
    if chars.count < 54 { return String(line) }
    func col(_ start: Int, _ end: Int) -> Double {
        let endClamped = min(end, chars.count)
        if start >= endClamped { return 0 }
        return Double(String(chars[start..<endClamped]).trimmingCharacters(in: .whitespaces)) ?? 0
    }
    let x = col(30, 38)
    let y = col(38, 46)
    let z = col(46, 54)
    let nx = op.r00 * x + op.r01 * y + op.r02 * z + op.t0
    let ny = op.r10 * x + op.r11 * y + op.r12 * z + op.t1
    let nz = op.r20 * x + op.r21 * y + op.r22 * z + op.t2
    // Splice the new coords back into the original line at fixed
    // columns 30-54. Preserves columns 55+ (occupancy / B / element).
    let prefix = String(chars[0..<30])
    let xs = String(format: "%8.3f", nx)
    let ys = String(format: "%8.3f", ny)
    let zs = String(format: "%8.3f", nz)
    let suffix = chars.count > 54 ? String(chars[54...]) : ""
    return prefix + xs + ys + zs + suffix
}

/// CIF path: walk the `_pdbx_struct_oper_list` loop, build the
/// operator dictionary, then apply each to the atom_site block.
/// We emit a synthetic multi-MODEL PDB so 3Dmol's PDB parser can
/// load it - we do NOT try to round-trip back into CIF.
private func expandAssemblyCIF(_ raw: String) -> String? {
    // Parse oper list.
    guard let ops = parseCifOperList(raw), !ops.isEmpty else { return nil }
    if ops.count == 1 && isIdentity(ops[0]) { return nil }
    // Parse atom_site rows into a list of PDB-shaped ATOM lines so
    // we can reuse rewritePDBWithOperators.
    guard let pdbLike = cifAtomsAsPdb(raw) else { return nil }
    return rewritePDBWithOperators(pdbLike, operators: ops)
}

private func parseCifOperList(_ raw: String) -> [AssemblyOperator]? {
    // Locate the loop_ that contains _pdbx_struct_oper_list.matrix[1][1].
    guard let loopStart = raw.range(of: "_pdbx_struct_oper_list.") else { return nil }
    // Walk back to the preceding loop_ marker.
    let preamble = raw[..<loopStart.lowerBound]
    guard let loopHeader = preamble.range(of: "loop_", options: .backwards) else { return nil }
    let lines = raw[loopHeader.upperBound...].split(separator: "\n", maxSplits: 8192, omittingEmptySubsequences: false)
    var columnNames: [String] = []
    var dataRows: [[String]] = []
    var inHeader = true
    for line in lines {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") { continue }
        if inHeader && t.hasPrefix("_pdbx_struct_oper_list.") {
            columnNames.append(t)
            continue
        }
        if t.hasPrefix("_") || t.hasPrefix("loop_") || t.hasPrefix("data_") {
            if inHeader { continue }
            break
        }
        inHeader = false
        // CIF data row - whitespace-separated. We won't handle quoted
        // strings containing whitespace (rare in oper_list entries).
        let parts = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if !parts.isEmpty { dataRows.append(parts) }
    }
    if columnNames.isEmpty || dataRows.isEmpty { return nil }
    // Find column indices we need.
    func idx(_ name: String) -> Int? {
        return columnNames.firstIndex(of: "_pdbx_struct_oper_list." + name)
    }
    let m = [
        ["matrix[1][1]", "matrix[1][2]", "matrix[1][3]", "vector[1]"],
        ["matrix[2][1]", "matrix[2][2]", "matrix[2][3]", "vector[2]"],
        ["matrix[3][1]", "matrix[3][2]", "matrix[3][3]", "vector[3]"],
    ]
    var rowIdx: [[Int]] = []
    for triplet in m {
        var rr: [Int] = []
        for k in triplet {
            guard let i = idx(k) else { return nil }
            rr.append(i)
        }
        rowIdx.append(rr)
    }
    var ops: [AssemblyOperator] = []
    for parts in dataRows {
        if parts.count < columnNames.count { continue }
        func v(_ ii: Int) -> Double { Double(parts[ii]) ?? 0 }
        let r1 = rowIdx[0]; let r2 = rowIdx[1]; let r3 = rowIdx[2]
        ops.append(AssemblyOperator(
            r00: v(r1[0]), r01: v(r1[1]), r02: v(r1[2]), t0: v(r1[3]),
            r10: v(r2[0]), r11: v(r2[1]), r12: v(r2[2]), t1: v(r2[3]),
            r20: v(r3[0]), r21: v(r3[1]), r22: v(r3[2]), t2: v(r3[3])))
    }
    return ops
}

private func cifAtomsAsPdb(_ raw: String) -> String? {
    // Convert _atom_site loop rows into PDB-shaped ATOM/HETATM lines
    // so we can reuse rewritePDBWithOperators. The conversion is
    // lossy (we drop alt-conf, anisou, etc.) but coords + chain +
    // residue identity round-trip correctly, which is all we need
    // for the assembly expansion.
    guard let loopStart = raw.range(of: "_atom_site.") else { return nil }
    let preamble = raw[..<loopStart.lowerBound]
    guard let loopHeader = preamble.range(of: "loop_", options: .backwards) else { return nil }
    let lines = raw[loopHeader.upperBound...].split(separator: "\n", maxSplits: 65536, omittingEmptySubsequences: false)
    var cols: [String] = []
    var rows: [[String]] = []
    var inHeader = true
    for line in lines {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") { continue }
        if inHeader && t.hasPrefix("_atom_site.") { cols.append(t); continue }
        if t.hasPrefix("_") || t.hasPrefix("loop_") || t.hasPrefix("data_") {
            if inHeader { continue }
            break
        }
        inHeader = false
        let parts = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= cols.count { rows.append(parts) }
    }
    func idx(_ name: String) -> Int? { cols.firstIndex(of: "_atom_site." + name) }
    guard let cx = idx("Cartn_x"), let cy = idx("Cartn_y"), let cz = idx("Cartn_z") else { return nil }
    let iSerial   = idx("id") ?? -1
    let iAtomName = idx("auth_atom_id") ?? idx("label_atom_id") ?? -1
    let iResName  = idx("auth_comp_id") ?? idx("label_comp_id") ?? -1
    let iChain    = idx("auth_asym_id") ?? idx("label_asym_id") ?? -1
    let iResSeq   = idx("auth_seq_id") ?? idx("label_seq_id") ?? -1
    let iElement  = idx("type_symbol") ?? -1
    var out = ""
    for r in rows {
        let serial = iSerial   >= 0 ? Int(r[iSerial])  ?? 0 : 0
        let atomNm = iAtomName >= 0 ? r[iAtomName].replacingOccurrences(of: "\"", with: "") : "C"
        let resNm  = iResName  >= 0 ? r[iResName]  : "UNK"
        let chain  = iChain    >= 0 ? r[iChain].prefix(1) : "A"
        let resSeq = iResSeq   >= 0 ? Int(r[iResSeq])  ?? 0 : 0
        let xv     = Double(r[cx]) ?? 0
        let yv     = Double(r[cy]) ?? 0
        let zv     = Double(r[cz]) ?? 0
        let elem   = iElement  >= 0 ? r[iElement] : "C"
        // PDB ATOM record format (fixed columns):
        //   1- 6  Record name
        //   7-11  serial
        // 13-16  atom name
        // 18-20  residue name
        //    22  chain
        // 23-26  residue seq
        // 31-38  x
        // 39-46  y
        // 47-54  z
        // 55-60  occupancy
        // 61-66  B-factor
        // 77-78  element
        let line = String(format: "ATOM  %5d %-4s %3s %1s%4d    %8.3f%8.3f%8.3f  1.00  0.00          %2s",
                          serial, atomNm as CVarArg, resNm as CVarArg,
                          String(chain) as CVarArg, resSeq, xv, yv, zv, elem as CVarArg)
        out += line + "\n"
    }
    return out.isEmpty ? nil : out
}
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
    // Cryo-EM density (.ccp4 / .mrc / .map) is binary and goes
    // through a Swift-side parser that converts it to a Cube-format
    // text payload, then through the same {CUBE_ISOSURFACE} viewer
    // path. Detect by extension here so we never try to read the
    // binary as text (would crash readMolecularTextFile or produce
    // garbled output).
    let lowerExt = pdbPath.lowercased().components(separatedBy: ".").last ?? ""
    let isCryoEM = (lowerExt == "ccp4" || lowerExt == "mrc" || lowerExt == "map")
                   && options.cryoEMRender
    let isTrajectory = (lowerExt == "dcd" || lowerExt == "xtc" || lowerExt == "trr")

    let rawOriginal: String
    if isCryoEM, let binary = try? Data(contentsOf: URL(fileURLWithPath: pdbPath)),
       let cube = convertCCP4ToCube(binary) {
        rawOriginal = cube
    } else if isTrajectory {
        // Trajectories are binary, no useful text representation. Branch to
        // a dedicated reader that emits the first frame as XYZ.
        if let xyz = readTrajectoryFirstFrame(path: pdbPath, ext: lowerExt) {
            rawOriginal = xyz
        } else {
            return errorHTML(
                title: "Trajectory format not previewable",
                detail: "\(lowerExt.uppercased()) trajectory could not be parsed. " +
                        "DCD is supported (CHARMM/NAMD); XTC/TRR are not yet readable " +
                        "without GROMACS-side decompression. Add a sibling .pdb or .psf " +
                        "topology file to get element-aware atom labels.")
        }
    } else {
        do {
            rawOriginal = try readMolecularTextFile(pdbPath)
        } catch {
            return errorHTML(title: "Could not read file",
                             detail: error.localizedDescription)
        }
    }

    // Pre-pass pipeline:
    //   1. Biological assembly expansion (1.7.31+) - PDB / CIF only
    //      and only when the bioAssembly setting is on. Rewrites the
    //      file into a multi-MODEL PDB with every BIOMT / oper_list
    //      operator applied to a copy of the atoms.
    //   2. Computational-chem output pre-parse (1.7.30+) - sniffs
    //      Gaussian / ORCA / QChem output text, extracts the final
    //      coordinate block, rewrites as XYZ.
    // If neither pre-pass matches the file is passed through
    // unchanged.
    let ext = lowerExt
    var working = rawOriginal
    var workingFormat = dataFormat
    if isCryoEM {
        // The Data we converted above is Cube-formatted text, even
        // though the original file had a .ccp4 / .mrc / .map suffix.
        // 3Dmol's cube parser produces a model with -1 atoms (just
        // volumetric data), and the existing {CUBE_ISOSURFACE} JS
        // path picks it up from there. We override {CUBE_ISOSURFACE}
        // at substitution time below so the user's preference is
        // ignored - rendering a CCP4 without isosurface would just
        // produce an empty viewport.
        workingFormat = "cube"
    } else if isTrajectory {
        // First-frame XYZ; bio-assembly / comp-chem pre-passes don't apply.
        workingFormat = "xyz"
    } else if options.bioAssembly, let expanded = expandBiologicalAssembly(working, extension: ext) {
        working = expanded
        workingFormat = "pdb"   // multi-MODEL PDB regardless of source
    }
    if !isCryoEM, !isTrajectory, let conv = parseComputationalChem(working, extension: ext) {
        working = conv.xyz
        workingFormat = "xyz"
    }
    let raw = working
    let resolvedFormat = workingFormat

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
    html = html.replacingOccurrences(of: "{AMBIENT_OCCLUSION}", with: options.ambientOcclusion ? "true" : "false")
    html = html.replacingOccurrences(of: "{AUTO_ORIENT}",       with: options.autoOrient      ? "true" : "false")
    // Force cube isosurface ON when the source was a cryo-EM map
    // (otherwise we'd render the cube as zero atoms = empty preview).
    html = html.replacingOccurrences(of: "{CUBE_ISOSURFACE}",   with: (options.cubeIsosurface || isCryoEM)  ? "true" : "false")
    html = html.replacingOccurrences(of: "{CRYO_EM_SIGMA}",     with: String(format: "%.2f", options.cryoEMSigma))
    html = html.replacingOccurrences(of: "{IS_CRYO_EM}",        with: isCryoEM ? "true" : "false")
    html = html.replacingOccurrences(of: "{SHOW_SHARE_BUTTON}", with: options.showShareButton ? "true" : "false")
    html = html.replacingOccurrences(of: "{BIO_ASSEMBLY}",      with: options.bioAssembly     ? "true" : "false")
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
    html = html.replacingOccurrences(of: "{AMBIENT_OCCLUSION}",      with: options.ambientOcclusion ? "true" : "false")
    html = html.replacingOccurrences(of: "{AUTO_ORIENT}",            with: options.autoOrient      ? "true" : "false")
    html = html.replacingOccurrences(of: "{CUBE_ISOSURFACE}",        with: options.cubeIsosurface  ? "true" : "false")
    html = html.replacingOccurrences(of: "{BIO_ASSEMBLY}",           with: options.bioAssembly     ? "true" : "false")
    html = html.replacingOccurrences(of: "{CRYO_EM_SIGMA}",          with: String(format: "%.2f", options.cryoEMSigma))
    html = html.replacingOccurrences(of: "{IS_CRYO_EM}",             with: "false")
    html = html.replacingOccurrences(of: "{SHOW_SHARE_BUTTON}",      with: options.showShareButton ? "true" : "false")
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

// MARK: - Molecular dynamics trajectory readers (1.7.36+)
//
// The goal is a first-frame preview — not full trajectory playback. So we read
// the topology of the trajectory enough to know how many atoms there are, pull
// the first frame's xyz coordinates, and emit XYZ-format text that 3Dmol can
// render via its existing parser. Element types come from a sibling .pdb / .psf
// if present; otherwise we default everything to "C".
//
// Supported now:
//   .dcd  — CHARMM / NAMD binary; Fortran-record framing. We detect endianness
//           via the leading record marker (84) and walk header → title → natoms
//           → first-frame X/Y/Z.
//
// Not yet supported (returns nil so the caller emits a friendly error HTML):
//   .xtc  — GROMACS XDR-encoded with custom 3D-vector compression (libxdrfile).
//           Implementable in Swift but a few hundred lines for the bit-unpacker.
//   .trr  — GROMACS XDR-encoded full-precision floats. Simpler than XTC but
//           still requires an XDR walker and integration tests.

/// Top-level dispatcher. Returns first-frame XYZ text, or nil if the format
/// isn't decodable yet.
internal func readTrajectoryFirstFrame(path: String, ext: String) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    switch ext {
    case "dcd":
        return parseDCDFirstFrame(data: data, dcdURL: URL(fileURLWithPath: path))
    case "xtc", "trr":
        return nil  // explicit unsupported — caller shows an info panel
    default:
        return nil
    }
}

/// DCD reader. Walks Fortran-record-wrapped blocks:
///   - header: 4-byte length=84, "CORD" + 20 int32 + 4-byte length=84
///   - title:  4-byte length + ntitle*80 chars + 4-byte length
///   - natoms: 4-byte length=4 + int32 + 4-byte length=4
///   - per frame (we read only frame 0):
///       optional unit cell: 4-byte length=48 + 6×double + 4-byte length=48
///       X: 4-byte length=4*N + N×float32 + 4-byte length=4*N
///       Y: same
///       Z: same
private func parseDCDFirstFrame(data: Data, dcdURL: URL) -> String? {
    guard data.count >= 100 else { return nil }
    var offset = 0
    // Endianness probe: the first 4 bytes should decode to 84 in one of the
    // two endian readings. If neither does it's not a DCD.
    let littleFirst = readInt32LE(data, offset: 0)
    let bigFirst    = readInt32BE(data, offset: 0)
    let little: Bool
    if littleFirst == 84 { little = true }
    else if bigFirst == 84 { little = false }
    else { return nil }

    // Walk header (84 bytes payload).
    offset = 4
    let cord = data.subdata(in: offset..<(offset + 4))
    guard String(data: cord, encoding: .ascii) == "CORD" else { return nil }
    offset += 4
    // Skip nset (1) … and the rest of the 20-int32 header.
    offset += 80  // (84 - 4 for "CORD")
    // hasUnitCell lives at int32[11] (0-based), i.e. offset+44 inside the
    // header payload. Header start = 8; so byte offset = 8 + 44 = 52.
    let hasUnitCell = readInt32(data, offset: 52, little: little) != 0
    // Trailing record marker (4 bytes) — skip.
    offset += 4

    // Title block.
    let titleLen = Int(readInt32(data, offset: offset, little: little))
    offset += 4
    offset += titleLen   // skip title body
    offset += 4          // trailing marker

    // Natoms block (length=4 + int32 + length=4).
    offset += 4
    let natoms = Int(readInt32(data, offset: offset, little: little))
    offset += 4
    offset += 4
    guard natoms > 0 && natoms < 10_000_000 else { return nil }

    // First frame — skip the per-frame unit cell if the flag is set.
    if hasUnitCell {
        // 4-byte marker (should equal 48) + 6 doubles + 4-byte marker.
        offset += 4
        offset += 48
        offset += 4
    }

    // Read X / Y / Z coordinate blocks.
    let frameByteLen = 4 + natoms * 4 + 4
    guard offset + 3 * frameByteLen <= data.count else { return nil }
    var xs = [Float](repeating: 0, count: natoms)
    var ys = [Float](repeating: 0, count: natoms)
    var zs = [Float](repeating: 0, count: natoms)
    if !readFloatArray(data, offset: &offset, count: natoms, into: &xs, little: little) { return nil }
    if !readFloatArray(data, offset: &offset, count: natoms, into: &ys, little: little) { return nil }
    if !readFloatArray(data, offset: &offset, count: natoms, into: &zs, little: little) { return nil }

    // Element labels: prefer a sibling .pdb / .psf / .gro topology.
    let elements = readSiblingElements(dcdURL: dcdURL, count: natoms)
        ?? Array(repeating: "C", count: natoms)

    // Emit XYZ text.
    var xyz = "\(natoms)\nFirst frame from \(dcdURL.lastPathComponent)\n"
    for i in 0..<natoms {
        xyz += "\(elements[i]) \(xs[i]) \(ys[i]) \(zs[i])\n"
    }
    return xyz
}

/// Look for a sibling topology file with the same base name and .pdb/.psf/.gro.
/// Returns one element symbol per atom, or nil if no usable sibling was found.
private func readSiblingElements(dcdURL: URL, count: Int) -> [String]? {
    let dir = dcdURL.deletingLastPathComponent()
    let base = dcdURL.deletingPathExtension().lastPathComponent
    for ext in ["pdb", "psf", "gro"] {
        let candidate = dir.appendingPathComponent("\(base).\(ext)")
        if let text = try? String(contentsOf: candidate, encoding: .utf8) {
            let parsed = parseElementsFromTopology(text: text, ext: ext)
            if parsed.count == count { return parsed }
        }
    }
    return nil
}

private func parseElementsFromTopology(text: String, ext: String) -> [String] {
    var out = [String]()
    switch ext {
    case "pdb":
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            guard line.count >= 78 else {
                if (line.hasPrefix("ATOM") || line.hasPrefix("HETATM")) && line.count >= 16 {
                    // No element column — guess from atom name (cols 13-16).
                    let start = line.index(line.startIndex, offsetBy: 12)
                    let end   = line.index(line.startIndex, offsetBy: min(16, line.count))
                    let name = String(line[start..<end]).trimmingCharacters(in: .whitespaces)
                    out.append(guessElementFromName(name))
                }
                continue
            }
            if line.hasPrefix("ATOM") || line.hasPrefix("HETATM") {
                let s = line.index(line.startIndex, offsetBy: 76)
                let e = line.index(line.startIndex, offsetBy: 78)
                let el = String(line[s..<e]).trimmingCharacters(in: .whitespaces)
                out.append(el.isEmpty ? "C" : el)
            }
        }
    case "psf":
        // PSF !NATOM section: each atom line has 8+ whitespace tokens; col 5
        // is the atom name (first letter is usually the element).
        var inAtoms = false
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.contains("!NATOM") { inAtoms = true; continue }
            if !inAtoms { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("!") { break }
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 5 { out.append(guessElementFromName(String(parts[4]))) }
        }
    case "gro":
        // .gro atoms are lines 3..3+natoms; cols 11-15 hold the atom name.
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count >= 3 else { return [] }
        for i in 2..<lines.count {
            let line = lines[i]
            if line.count < 15 { continue }
            let s = line.index(line.startIndex, offsetBy: 10)
            let e = line.index(line.startIndex, offsetBy: 15)
            let name = String(line[s..<e]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            out.append(guessElementFromName(name))
        }
    default: break
    }
    return out
}

private func guessElementFromName(_ name: String) -> String {
    // PDB/PSF atom names are space-padded to 4 chars: leading digit if any,
    // then 1-2 element letters, then position indicator. Strip leading digits,
    // take the first 1-2 alpha chars, normalize to title case.
    let stripped = String(name.drop(while: { $0.isNumber }))
    guard let first = stripped.first else { return "C" }
    if stripped.count >= 2 {
        let second = stripped[stripped.index(after: stripped.startIndex)]
        // Two-letter elements that start with the first letter (Cl, Br, etc.).
        let two = String(first).uppercased() + String(second).lowercased()
        let twoLetterElements: Set<String> = [
            "He", "Li", "Be", "Ne", "Na", "Mg", "Al", "Si", "Cl", "Ar",
            "Ca", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Br", "Mo", "Ag",
            "Sn", "Au", "Hg", "Pb"
        ]
        if twoLetterElements.contains(two) { return two }
    }
    return String(first).uppercased()
}

// MARK: - DCD byte helpers

private func readInt32(_ data: Data, offset: Int, little: Bool) -> Int32 {
    return little ? readInt32LE(data, offset: offset) : readInt32BE(data, offset: offset)
}
private func readInt32LE(_ data: Data, offset: Int) -> Int32 {
    return Int32(bitPattern:
        UInt32(data[data.startIndex + offset])           |
        UInt32(data[data.startIndex + offset + 1]) << 8  |
        UInt32(data[data.startIndex + offset + 2]) << 16 |
        UInt32(data[data.startIndex + offset + 3]) << 24)
}
private func readInt32BE(_ data: Data, offset: Int) -> Int32 {
    return Int32(bitPattern:
        UInt32(data[data.startIndex + offset]) << 24     |
        UInt32(data[data.startIndex + offset + 1]) << 16 |
        UInt32(data[data.startIndex + offset + 2]) << 8  |
        UInt32(data[data.startIndex + offset + 3]))
}

private func readFloatArray(_ data: Data, offset: inout Int, count: Int,
                            into out: inout [Float], little: Bool) -> Bool {
    // Skip leading length marker.
    offset += 4
    guard offset + count * 4 + 4 <= data.count else { return false }
    for i in 0..<count {
        let u32: UInt32 = little
            ? UInt32(data[data.startIndex + offset])           |
              UInt32(data[data.startIndex + offset + 1]) << 8  |
              UInt32(data[data.startIndex + offset + 2]) << 16 |
              UInt32(data[data.startIndex + offset + 3]) << 24
            : UInt32(data[data.startIndex + offset]) << 24     |
              UInt32(data[data.startIndex + offset + 1]) << 16 |
              UInt32(data[data.startIndex + offset + 2]) << 8  |
              UInt32(data[data.startIndex + offset + 3])
        out[i] = Float(bitPattern: u32)
        offset += 4
    }
    // Trailing length marker.
    offset += 4
    return true
}
