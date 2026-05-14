//
//  PreviewViewController.swift
//  QLExtension
//
//  Created by Jethro Hemmann on 15.08.21.
//

import Cocoa
import Quartz
import WebKit
import SwiftUI
import os.log

/// Subsystem-tagged logger so the user can grep for our extension's messages via:
///     log show --predicate 'subsystem == "com.ariomoniri.QuickLookProtein.QLExtension"' --info --last 2m
/// Quick Look extensions run in their own process and stdout/NSLog output is
/// otherwise hard to find. Use os_log so messages are stored in unified logging
/// even if no Console viewer is open at the time.
private let qlLog = OSLog(subsystem: "com.ariomoniri.QuickLookProtein.QLExtension",
                          category: "preview")

/// `@objc(QLPreviewPreviewViewController)` pins this class to an explicit
/// Obj-C runtime name so PluginKit's `NSClassFromString(NSExtensionPrincipalClass)`
/// lookup actually finds it. Without the attribute, Swift mangles the class name
/// (e.g. `_TtC11QLExtension21PreviewViewController`) and macOS's PluginKit host
/// silently can't instantiate the principal class — Quick Look then falls back
/// to its generic blank document preview, which is exactly what we saw when
/// `qlmanage -p` rendered a doc icon for both 6oc6.pdb and methane.pqr.
/// Keep `NSExtensionPrincipalClass` in Info.plist in sync with the name below.
@objc(QLPreviewPreviewViewController)
class PreviewViewController: NSViewController,
                             QLPreviewingController,
                             WKNavigationDelegate,
                             WKUIDelegate,
                             WKScriptMessageHandler {

    var webView: WKWebView?
    private var pendingHandler: ((Error?) -> Void)?
    /// Path of the most recently previewed file. Used by the Share
    /// handler to re-parse atoms for USDZ export (1.7.42+) without
    /// keeping the full atom array in memory between preview load
    /// and share click.
    private var currentSourceURL: URL?

    // Settings are intentionally NOT cached on the view controller. The
    // Quick Look daemon keeps an extension process warm across many
    // previews; if we initialised SettingsStorage once at load time, a
    // toggle flipped in the main app afterwards (e.g. "Show molecular
    // surface") would never propagate — the cached @Published values
    // are only read from UserDefaults inside SettingsStorage.init().
    // Re-instantiate on every preparePreviewOfFile so a fresh snapshot
    // of the App-Group preferences is picked up each time.

    /// Anything above this is refused with an in-page message — Quick Look extensions
    /// have a small memory budget and parsing a 50 MB PDB inside WKWebView will get the
    /// host process jetsam'd before we can render anything useful.
    // 25 MB ceiling for text files; cryo-EM .ccp4 / .mrc / .map
    // density maps can run up to ~250 MB for box sizes of 512^3 + so
    // we lift the cap when one of those extensions is in play.
    private let maxPreviewBytes:       Int = 25 * 1024 * 1024
    private let maxPreviewBytesCryoEM: Int = 500 * 1024 * 1024

    override var nibName: NSNib.Name? {
        return NSNib.Name("PreviewViewController")
    }

    override func loadView() {
        super.loadView()

        let webConfiguration = WKWebViewConfiguration()
        // Share-button (1.7.33+) bridge: viewer.html posts the rendered
        // PNG via window.webkit.messageHandlers.shareImage.postMessage,
        // we receive it in userContentController(_:didReceive:) below,
        // decode the data URI, drop it to a temp file, and present
        // NSSharingServicePicker over the WebView so the user can
        // AirDrop/Mail/Save without leaving Quick Look.
        webConfiguration.userContentController.add(self, name: "shareImage")
        let webView = WKWebView(frame: view.bounds, configuration: webConfiguration)
        webView.autoresizingMask = [.height, .width]
        webView.setValue(false, forKeyPath: "drawsBackground")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.view.addSubview(webView)
        self.webView = webView
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        os_log("preparePreviewOfFile called for %{public}@", log: qlLog, type: .info, url.path)
        self.currentSourceURL = url

        guard let htmlPath = Bundle.main.path(forResource: "3Dmol_viewer", ofType: "html") else {
            os_log("Viewer template missing from bundle", log: qlLog, type: .error)
            handler(NSError(domain: "QuickLookProtein", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Viewer template missing from bundle"]))
            return
        }
        os_log("htmlPath = %{public}@", log: qlLog, type: .info, htmlPath)

        let fileExtension = url.pathExtension.lowercased()
        let dataFormat = Settings.dataFormat(forExtension: fileExtension) ?? "pdb"
        os_log("ext=%{public}@ → format=%{public}@", log: qlLog, type: .info, fileExtension, dataFormat)

        let html: String
        let cap = (fileExtension == "ccp4" || fileExtension == "mrc" || fileExtension == "map")
                  ? maxPreviewBytesCryoEM : maxPreviewBytes
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > cap {
            // Render an in-page message rather than returning an error — Quick Look
            // shows a blank preview when the handler is called with an error.
            html = oversizedFileHTML(name: url.lastPathComponent,
                                     sizeMB: Double(size) / 1_048_576)
        } else {
            let userSettings = SettingsStorage()
            let options = ViewerOptions.from(
                userSettings,
                fileExtension: fileExtension,
                fileName: url.lastPathComponent
            )

            // Multi-file merge: when the user picked "Merge all in
            // same folder" in Settings, find every sibling structure
            // file we can read (App-Sandbox permitting) and hand the
            // whole set to the multi-model viewer template. Reads
            // that fail in the sandbox are silently dropped - we
            // still render the originally-requested file, just
            // without its neighbours.
            let mergeMode = userSettings.multiFilePreviewMode == .mergeFolder
            if mergeMode,
               let siblings = collectMergeSiblings(forFileAt: url),
               siblings.count > 1 {
                os_log("merge mode: combining %{public}d files",
                       log: qlLog, type: .info, siblings.count)
                html = prepare3DmolHTMLMulti(
                    htmlPath: htmlPath,
                    files: siblings,
                    options: options
                )
            } else {
                html = prepare3DmolHTML(
                    htmlPath: htmlPath,
                    pdbPath: url.path,
                    dataFormat: dataFormat,
                    options: options
                )
            }
        }

        // Quick Look can re-invoke this method on rapid scrubs through Finder. Fire any
        // pending handler from a prior invocation so the system doesn't time out waiting
        // for it.
        if let prev = pendingHandler {
            prev(nil)
        }

        let baseUrl = URL(fileURLWithPath: htmlPath)
        self.pendingHandler = handler
        os_log("loadHTMLString len=%{public}d baseURL=%{public}@",
               log: qlLog, type: .info, html.count, baseUrl.path)
        self.webView?.loadHTMLString(html, baseURL: baseUrl)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        os_log("WKWebView didFinish", log: qlLog, type: .info)
        pendingHandler?(nil)
        pendingHandler = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        os_log("WKWebView didFail: %{public}@", log: qlLog, type: .error, error.localizedDescription)
        // Even on failure, returning `nil` lets the (possibly partial) HTML show; a
        // non-nil error blanks the preview and the user sees nothing.
        pendingHandler?(nil)
        pendingHandler = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        os_log("WKWebView didFailProvisional: %{public}@", log: qlLog, type: .error, error.localizedDescription)
        pendingHandler?(nil)
        pendingHandler = nil
    }

    // MARK: - WKScriptMessageHandler (1.7.33+ Share button)

    /// Receive the data-URI PNG from viewer.html's Share button,
    /// drop it into a temp `.png` file, then present the system
    /// Sharing picker anchored to the WebView so the user can
    /// AirDrop / Mail / Save the rendering. Quick Look extensions
    /// are sandboxed but `NSSharingServicePicker` is a documented
    /// exception - the picker itself runs in a different process
    /// and can read our temp file via the handle we pass it.
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "shareImage",
              let dataURI = message.body as? String,
              let pngData = decodeDataURIPNG(dataURI) else { return }
        // Write to <tmp>/QuickLookProtein-<timestamp>.png. Using the
        // shared App Group container would be cleaner but our
        // sandbox permits NSTemporaryDirectory() too and the
        // Sharing picker reads the URL we hand it directly.
        let stamp = String(format: "%.0f", Date().timeIntervalSince1970)
        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QuickLookProtein-\(stamp).png")
        do {
            try pngData.write(to: pngURL, options: .atomic)
        } catch {
            os_log("share: could not write temp png: %{public}@", log: qlLog, type: .error, error.localizedDescription)
            return
        }

        // 1.7.42+ USDZ export: re-parse the source file (the roadmap's
        // recommended "no lifecycle state" option — ~20ms for typical
        // proteins) and write a `.usdz` next to the PNG. When the user
        // AirDrops both files to an iPad, the receiving Files app picks
        // the USDZ for AR Quick Look. Soft-cap structures over
        // USDZExporter.softAtomCap so we don't ship 10+ MB archives.
        var items: [URL] = [pngURL]
        let userSettings = SettingsStorage()
        if userSettings.includeUSDZInShare,
           let sourceURL = self.currentSourceURL {
            let ext = sourceURL.pathExtension.lowercased()
            if let atoms = MoleculeModel.parseAtoms(from: sourceURL, ext: ext),
               !atoms.isEmpty {
                if atoms.count > USDZExporter.softAtomCap {
                    os_log("share: skipping USDZ for %{public}d atoms (over soft cap %{public}d)",
                           log: qlLog, type: .info, atoms.count, USDZExporter.softAtomCap)
                } else {
                    let usdzURL = pngURL.deletingPathExtension().appendingPathExtension("usdz")
                    do {
                        try USDZExporter.export(atoms: atoms, to: usdzURL)
                        items.append(usdzURL)
                        os_log("share: wrote USDZ (%{public}d atoms) at %{public}@",
                               log: qlLog, type: .info, atoms.count, usdzURL.path)
                    } catch {
                        os_log("share: USDZ export failed: %{public}@",
                               log: qlLog, type: .error, String(describing: error))
                    }
                }
            } else {
                os_log("share: USDZ skipped — could not parse atoms from %{public}@",
                       log: qlLog, type: .info, sourceURL.lastPathComponent)
            }
        }

        guard let webView = self.webView else { return }
        let shareItems = items
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: shareItems)
            picker.show(relativeTo: NSRect(x: webView.bounds.maxX - 80,
                                           y: webView.bounds.maxY - 80,
                                           width: 1, height: 1),
                        of: webView,
                        preferredEdge: .minY)
        }
    }

    /// Decode `data:image/png;base64,...` -> Data. Returns nil on any
    /// shape that isn't a base64-encoded PNG, so a malformed URI from
    /// the JS side can't crash the extension.
    private func decodeDataURIPNG(_ uri: String) -> Data? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[..<comma]
        guard header.contains("image/png"), header.contains("base64") else { return nil }
        let b64 = uri[uri.index(after: comma)...]
        return Data(base64Encoded: String(b64))
    }
}
