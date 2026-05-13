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
    var fileName: String

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
            fileName:        fileName
        )
    }
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
    let raw: String
    do {
        raw = try readMolecularTextFile(pdbPath)
    } catch {
        return errorHTML(title: "Could not read file",
                         detail: error.localizedDescription)
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
    html = html.replacingOccurrences(of: "{DATA_FORMAT}",       with: dataFormat)
    html = html.replacingOccurrences(of: "{AUTO_STYLE_HETERO}", with: options.autoStyleHetero ? "true" : "false")
    html = html.replacingOccurrences(of: "{SHOW_SURFACE}",      with: options.showSurface      ? "true" : "false")
    html = html.replacingOccurrences(of: "{HIDE_H}",            with: options.hideHydrogens    ? "true" : "false")
    html = html.replacingOccurrences(of: "{SHOW_UNIT_CELL}",    with: options.showUnitCell     ? "true" : "false")
    html = html.replacingOccurrences(of: "{SHOW_INFO}",         with: options.showInfoOverlay  ? "true" : "false")
    html = html.replacingOccurrences(of: "{FILE_NAME}",         with: escapeForHTMLAttribute(options.fileName))
    html = html.replacingOccurrences(of: "{THUMBNAIL_MODE}",    with: thumbnailMode ? "true" : "false")
    html = html.replacingOccurrences(of: "{MOL_DATA}",          with: safeData)
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
