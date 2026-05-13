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

class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate, WKUIDelegate {

    var webView: WKWebView?
    private var pendingHandler: ((Error?) -> Void)?

    // Note: @StateObject is a SwiftUI property wrapper that needs a View's lifecycle to
    // publish changes — plain ownership is what we want on an NSViewController.
    private let userSettings = SettingsStorage()

    /// Anything above this is refused with an in-page message — Quick Look extensions
    /// have a small memory budget and parsing a 50 MB PDB inside WKWebView will get the
    /// host process jetsam'd before we can render anything useful.
    private let maxPreviewBytes: Int = 25 * 1024 * 1024

    override var nibName: NSNib.Name? {
        return NSNib.Name("PreviewViewController")
    }

    override func loadView() {
        super.loadView()

        let webConfiguration = WKWebViewConfiguration()
        let webView = WKWebView(frame: view.bounds, configuration: webConfiguration)
        webView.autoresizingMask = [.height, .width]
        webView.setValue(false, forKeyPath: "drawsBackground")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.view.addSubview(webView)
        self.webView = webView
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        guard let htmlPath = Bundle.main.path(forResource: "3Dmol_viewer", ofType: "html") else {
            handler(NSError(domain: "QuickLookProtein", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Viewer template missing from bundle"]))
            return
        }

        let fileExtension = url.pathExtension.lowercased()
        let dataFormat = Settings.dataFormat(forExtension: fileExtension) ?? "pdb"

        let html: String
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > maxPreviewBytes {
            // Render an in-page message rather than returning an error — Quick Look
            // shows a blank preview when the handler is called with an error.
            html = oversizedFileHTML(name: url.lastPathComponent,
                                     sizeMB: Double(size) / 1_048_576)
        } else {
            let options = ViewerOptions.from(
                userSettings,
                fileExtension: fileExtension,
                fileName: url.lastPathComponent
            )
            html = prepare3DmolHTML(
                htmlPath: htmlPath,
                pdbPath: url.path,
                dataFormat: dataFormat,
                options: options
            )
        }

        // Quick Look can re-invoke this method on rapid scrubs through Finder. Fire any
        // pending handler from a prior invocation so the system doesn't time out waiting
        // for it.
        if let prev = pendingHandler {
            prev(nil)
        }

        let baseUrl = URL(fileURLWithPath: htmlPath)
        self.pendingHandler = handler
        self.webView?.loadHTMLString(html, baseURL: baseUrl)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pendingHandler?(nil)
        pendingHandler = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Even on failure, returning `nil` lets the (possibly partial) HTML show; a
        // non-nil error blanks the preview and the user sees nothing.
        pendingHandler?(nil)
        pendingHandler = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        pendingHandler?(nil)
        pendingHandler = nil
    }
}
