//
//  ThumbnailProvider.swift
//  QLThumbnail
//
//  Generates per-file Finder thumbnails for molecular structure files.
//
//  Why this file is fully self-contained (no `import` of shared types,
//  no `Settings` / `ViewerOptions` / `prepare3DmolHTML` references):
//
//      Xcode's QLThumbnail target was added via the wizard with a
//      `PBXFileSystemSynchronizedRootGroup`, which auto-includes
//      everything inside `QLThumbnail/` but nothing outside. Adding the
//      Shared/ Swift files to the target's membership requires four
//      click-throughs in Xcode's UI per file — a friction point we
//      avoid by inlining the small amount of logic we need.
//
//      We do NOT duplicate `3Dmol.js` or `3Dmol_viewer.html` though —
//      those live in the host app's Resources directory (already added
//      as resources of the main app target). At runtime we compute the
//      host bundle URL from our `.appex` location (great-grandparent of
//      `Bundle.main.bundleURL`) and pass it as the WKWebView's baseURL.
//      Apple's sandbox grants app extensions read access to the host
//      app's bundle resources, so this works in shipped + signed builds.
//

import Cocoa
import QuickLookThumbnailing
import WebKit
import os.log

/// Subsystem-tagged logger — paired with QLExtension's. Stream messages from
/// both Quick Look surfaces with:
///     log show --info --predicate 'subsystem BEGINSWITH "com.ariomoniri.QuickLookProtein"' --last 2m
private let thumbLog = OSLog(subsystem: "com.ariomoniri.QuickLookProtein.QLThumbnail",
                             category: "thumbnail")

// The @objc attribute is load-bearing: NSExtensionPrincipalClass in our
// Info.plist points at "QLThumbnail.ThumbnailProvider" and PluginKit looks
// the class up via NSClassFromString. Swift NSObject subclasses USUALLY get
// @objc inferred for free, but in some build configurations (final class,
// indirect NSObject inheritance via QLThumbnailProvider → NSExtension →
// NSObject, Swift 5.10+ inference rules) the class doesn't end up in the
// Obj-C runtime — confirmed via `nm` on the built executable. Without it
// PluginKit silently fails to register the extension.
@objc(QLThumbnailThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider, WKNavigationDelegate, WKScriptMessageHandler {

    // MARK: Tunables -----------------------------------------------------------

    /// Skip files larger than this — a 100 MB PDB would jetsam the
    /// thumbnail extension before we got anywhere near rendering it.
    private let maxBytes = 25 * 1024 * 1024

    /// macOS kills thumbnail extensions after ~8 s. Stop earlier so we have
    /// time to package a snapshot reply on the way out.
    private let renderTimeout: TimeInterval = 5.5

    // MARK: Per-request state --------------------------------------------------

    private var window: NSWindow?
    private var webView: WKWebView?
    private var handler: ((QLThumbnailReply?, Error?) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var size: CGSize = .zero
    private var didReply = false

    // MARK: QLThumbnailProvider -----------------------------------------------

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {

        let ext = request.fileURL.pathExtension.lowercased()
        os_log("provideThumbnail called for %{public}@ (ext=%{public}@, size=%{public}.0fx%{public}.0f)",
               log: thumbLog, type: .info,
               request.fileURL.path, ext,
               request.maximumSize.width, request.maximumSize.height)

        // CUBE files are volumetric — without an isosurface they'd render as
        // a sparse dust of nuclei, which makes a misleading icon. Decline and
        // let Finder use the system default.
        if ext == "cube" || ext == "cub" {
            handler(nil, nil)
            return
        }

        guard let dataFormat = self.formatToken(for: ext) else {
            handler(nil, self.error(code: 1, message: "Unsupported file type: .\(ext)"))
            return
        }

        // Size cap — checked before reading the file.
        if let attrSize = (try? FileManager.default.attributesOfItem(atPath: request.fileURL.path))?[.size] as? Int,
           attrSize > self.maxBytes {
            handler(nil, self.error(code: 2, message: "File too large for thumbnail (\(attrSize / 1_048_576) MB)"))
            return
        }

        // Read the file. Latin-1 fallback covers CIFs with non-ASCII author
        // names; without it we'd reject files an ASCII-only UTF-8 parser
        // wouldn't have rejected either.
        let data: String
        do {
            data = try Self.readText(at: request.fileURL)
        } catch {
            handler(nil, error)
            return
        }

        // Viewer template + 3Dmol.js are bundled INSIDE this extension's own
        // .appex (copied into QLThumbnail/ so the synchronised file-system
        // group picks them up automatically). Earlier versions tried to read
        // them from the host app's Resources directory but the sandboxed
        // WebContent process can't follow file:// URLs across the
        // .appex → host bundle boundary reliably, which made the WebView
        // hang while 3Dmol.js silently failed to load. Self-bundling
        // duplicates ~4 MB but is the only sandbox-safe path.
        guard let templateURL = Bundle.main.url(forResource: "3Dmol_viewer", withExtension: "html"),
              let template = try? String(contentsOf: templateURL, encoding: .utf8) else {
            handler(nil, self.error(code: 3, message: "Viewer template not found in extension bundle"))
            return
        }

        // Hand the resolved values off to the renderer.
        self.handler = handler
        self.size = request.maximumSize
        self.didReply = false

        let html = self.renderTemplate(template,
                                       moleculeData: data,
                                       dataFormat: dataFormat,
                                       fileName: request.fileURL.lastPathComponent)

        os_log("rendering HTML len=%{public}d dataFormat=%{public}@",
               log: thumbLog, type: .info, html.count, dataFormat)
        DispatchQueue.main.async { [weak self] in
            self?.startRender(html: html, baseURL: templateURL)
        }
    }

    // MARK: Render ------------------------------------------------------------

    private func startRender(html: String, baseURL: URL) {
        // Off-screen NSWindow with `alphaValue: 0.01` is the load-bearing
        // trick for headless WebGL — a fully transparent (0.0) window is
        // skipped by the compositor and `WKWebView` then renders a blank
        // canvas; 0.01 keeps it in the scene graph.
        let frame = NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.alphaValue = 0.01
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.makeKeyAndOrderFront(nil)

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "qlThumbnailReady")

        let webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        webView.wantsLayer = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        window.contentView = webView

        self.window = window
        self.webView = webView

        // Fail-safe — if the JS never signals ready (broken file, WebGL
        // disabled, parse error) we still return *something* to Finder.
        let timeout = DispatchWorkItem { [weak self] in
            self?.replyWithCurrentSnapshot()
        }
        self.timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + renderTimeout, execute: timeout)

        webView.loadHTMLString(html, baseURL: baseURL)
    }

    // MARK: Bridge & reply paths ----------------------------------------------

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "qlThumbnailReady",
              let dataURI = message.body as? String else { return }
        replyWithDataURI(dataURI)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        replyWithError(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        replyWithError(error)
    }

    private func replyWithDataURI(_ uri: String) {
        guard !didReply else { return }
        didReply = true
        timeoutWorkItem?.cancel()
        os_log("qlThumbnailReady fired (len=%{public}d)", log: thumbLog, type: .info, uri.count)

        // `data:image/png;base64,XXXX`. We don't try to be clever about
        // decoding malformed URIs — if it's not a clean PNG, fall back.
        guard let comma = uri.firstIndex(of: ","),
              let pngData = Data(base64Encoded: String(uri[uri.index(after: comma)...]),
                                 options: .ignoreUnknownCharacters),
              let image = NSImage(data: pngData) else {
            replyWithError(self.error(code: 4, message: "Could not decode rendered image"))
            return
        }
        finishWith(image: image)
    }

    private func replyWithCurrentSnapshot() {
        guard !didReply else { return }
        didReply = true
        os_log("render timeout — falling back to webView snapshot",
               log: thumbLog, type: .error)
        webView?.takeSnapshot(with: nil) { [weak self] image, error in
            if let image = image {
                self?.finishWith(image: image)
            } else {
                self?.handler?(nil, error)
                self?.cleanup()
            }
        }
    }

    private func replyWithError(_ error: Error) {
        guard !didReply else { return }
        didReply = true
        timeoutWorkItem?.cancel()
        handler?(nil, error)
        cleanup()
    }

    private func finishWith(image: NSImage) {
        let size = self.size
        let reply = QLThumbnailReply(contextSize: size) { _ -> Bool in
            // Aspect-preserving fit so the rendered protein never stretches.
            let imgSize = image.size
            let scale = min(size.width / imgSize.width, size.height / imgSize.height)
            let drawW = imgSize.width * scale
            let drawH = imgSize.height * scale
            let rect = NSRect(x: (size.width  - drawW) / 2,
                              y: (size.height - drawH) / 2,
                              width: drawW, height: drawH)
            image.draw(in: rect)
            return true
        }
        handler?(reply, nil)
        cleanup()
    }

    private func cleanup() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "qlThumbnailReady")
        webView?.stopLoading()
        webView = nil
        window?.close()
        window = nil
        handler = nil
    }

    // MARK: Helpers — file I/O & format ---------------------------------------

    private static func readText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8)     { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        throw NSError(domain: "QuickLookProtein.Thumbnail", code: 5,
                      userInfo: [NSLocalizedDescriptionKey:
                                    "File is not text in a recognised encoding"])
    }

    /// Map a file extension to the 3Dmol.js `addModel` format token. Mirrors
    /// `Settings.dataFormat(forExtension:)` in the shared code — kept here so
    /// this extension doesn't depend on Shared/.
    private func formatToken(for ext: String) -> String? {
        switch ext {
        case "pdb", "ent":     return "pdb"
        case "pdbqt":          return "pdbqt"
        case "pqr":            return "pqr"     // PDB + per-atom charge/radius (APBS/PDB2PQR)
        case "cif", "mmcif":   return "cif"
        case "sdf":            return "sdf"
        case "mol":            return "sdf"     // 3Dmol parses single MOL via the SDF parser
        case "mol2":           return "mol2"
        case "xyz":            return "xyz"
        case "gro":            return "gro"
        case "prmtop", "top":  return "prmtop"  // AMBER topology
        case "cube", "cub":    return "cube"    // declined above; included for completeness
        case "vasp", "poscar": return "vasp"
        case "cdjson", "json": return "cdjson"  // ChemDoodle JSON (3Dmol native)
        default:               return nil
        }
    }

    // MARK: Helpers — viewer-template substitution ----------------------------

    /// Hand-rolled minimal version of the shared `prepare3DmolHTML` — fills in
    /// every placeholder the bundled `3Dmol_viewer.html` recognises, using
    /// thumbnail-appropriate defaults (rotation off, info overlay off,
    /// thumbnail mode on so the JS posts a PNG back via the message bridge).
    private func renderTemplate(_ template: String,
                                moleculeData: String,
                                dataFormat: String,
                                fileName: String) -> String {
        let safeData = self.sanitizeForScriptBlock(moleculeData)
        let safeName = self.escapeForHTMLAttribute(fileName)

        // For PDB / CIF / mmCIF the default style is cartoon (the viewer
        // template's smart-styling auto-promotes to surface in thumbnail mode
        // for proteins). For small-molecule formats stick is the only
        // sensible default at icon size.
        let atomStyle = (dataFormat == "pdb" || dataFormat == "cif") ? "cartoon" : "stick"

        var html = template
        let pairs: [(String, String)] = [
            ("{ATOM_STYLE}",        atomStyle),
            ("{COLOR_SCHEME}",      "spectrum"),
            ("{BG_COLOR}",          "000000"),
            ("{BG_ALPHA}",          "0.0"),
            ("{ROTATION_SPEED}",    "0"),
            ("{DATA_FORMAT}",       dataFormat),
            ("{AUTO_STYLE_HETERO}", "true"),
            ("{SHOW_SURFACE}",      "false"),  // viewer auto-forces surface for proteins in thumbnail mode
            ("{HIDE_H}",            "false"),
            ("{SHOW_UNIT_CELL}",    "false"),
            ("{SHOW_INFO}",         "false"),
            ("{FILE_NAME}",         safeName),
            ("{ZOOM_FACTOR}",       "1.0"),
            ("{ZOOM_IS_AUTO}",      "true"),
            ("{THUMBNAIL_MODE}",    "true"),
            // Data block must be substituted *last* so an `{ATOM_STYLE}`
            // appearing inside the molecule file (unlikely but possible)
            // can't get replaced a second time.
            ("{MOL_DATA}",          safeData),
        ]
        for (placeholder, value) in pairs {
            html = html.replacingOccurrences(of: placeholder, with: value)
        }
        return html
    }

    /// Neutralise the only sequence that can break out of a
    /// `<script type="text/plain">` element. Also strips NULs and a leading
    /// UTF-8 BOM because 3Dmol's text parsers don't tolerate either.
    private func sanitizeForScriptBlock(_ s: String) -> String {
        var out = s
        if out.hasPrefix("\u{FEFF}") { out.removeFirst() }
        out = out.replacingOccurrences(of: "\u{0000}", with: "")
        out = out.replacingOccurrences(of: "</script",
                                       with: "<\\/script",
                                       options: .caseInsensitive)
        out = out.replacingOccurrences(of: "<!--", with: "<\\!--")
        out = out.replacingOccurrences(of: "-->",  with: "--\\>")
        return out
    }

    /// Filename ends up inside a JS string literal in the template; strip
    /// characters that could break out (and curly braces to prevent any
    /// stray `{TOKEN}` in the filename from colliding with our substitutions).
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

    // MARK: Helpers — misc -----------------------------------------------------

    private func error(code: Int, message: String) -> NSError {
        NSError(domain: "QuickLookProtein.Thumbnail", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
