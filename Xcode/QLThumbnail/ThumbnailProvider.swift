//
//  ThumbnailProvider.swift
//  QLThumbnail
//
//  Renders a still PNG thumbnail of a molecular file for Finder icons, Cover Flow,
//  and Gallery view. Uses the shared 3Dmol viewer template but with rotation off,
//  info overlay off, and a small handshake: when 3Dmol has finished its first frame
//  it calls `window.qlThumbnailReady(viewer.pngURI())` which is bridged back here
//  via a WKScriptMessageHandler.
//

import Cocoa
import QuickLookThumbnailing
import WebKit

final class ThumbnailProvider: QLThumbnailProvider, WKNavigationDelegate, WKScriptMessageHandler {

    /// Hard cap so a 100 MB PDB never gets parsed inside the thumbnail process.
    private let maxBytes = 25 * 1024 * 1024
    /// Apple kills the thumbnail extension after ~8s. Stop earlier to leave time to
    /// return a reply.
    private let renderTimeout: TimeInterval = 5.5

    private var window: NSWindow?
    private var webView: WKWebView?
    private var handler: ((QLThumbnailReply?, Error?) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var size: CGSize = .zero
    private var didReply = false

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {

        let ext = request.fileURL.pathExtension.lowercased()
        guard let htmlPath = Bundle.main.path(forResource: "3Dmol_viewer", ofType: "html"),
              let dataFormat = Settings.dataFormat(forExtension: ext) else {
            handler(nil, NSError(domain: "QuickLookProtein.Thumbnail", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "Unsupported file type"]))
            return
        }
        // CUBE files are volumetric — without isosurface rendering they're just a sparse
        // dust of nuclei, making for misleading thumbnails. Fall back to the system icon.
        if ext == "cube" || ext == "cub" {
            handler(nil, nil)
            return
        }

        // Size-cap early; large files are useless as thumbnails anyway.
        if let size = (try? FileManager.default.attributesOfItem(atPath: request.fileURL.path))?[.size] as? Int,
           size > maxBytes {
            handler(nil, NSError(domain: "QuickLookProtein.Thumbnail", code: 2,
                                 userInfo: [NSLocalizedDescriptionKey: "File too large for thumbnail"]))
            return
        }

        var options = ViewerOptions.from(SettingsStorage(),
                                         fileExtension: ext,
                                         fileName: request.fileURL.lastPathComponent)
        // Thumbnails: no rotation, no overlay, no surface, transparent background.
        options.rotationSpeed   = .noRotation
        options.showInfoOverlay = false
        options.showSurface     = false
        options.showUnitCell    = false

        let html = prepare3DmolHTML(
            htmlPath: htmlPath,
            pdbPath: request.fileURL.path,
            dataFormat: dataFormat,
            options: options,
            thumbnailMode: true
        )

        self.handler = handler
        self.size = request.maximumSize
        self.didReply = false

        // WKWebView must be on the main thread; the snapshot route requires the view
        // be in a window (off-screen is fine).
        DispatchQueue.main.async { [weak self] in
            self?.startRender(html: html, baseURL: URL(fileURLWithPath: htmlPath))
        }
    }

    private func startRender(html: String, baseURL: URL) {
        // The window must be visible to the window server for WebGL contexts inside
        // WKWebView to actually render. A fully transparent (alphaValue = 0) window
        // can be skipped by the compositor; offscreen + alpha 0.01 + makeKeyAndOrderFront
        // is the documented workaround for headless snapshots.
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

        // Fail-safe timeout — if the JS never signals ready (broken file, WebGL not
        // available, etc.) we still return *something* to Quick Look.
        let timeout = DispatchWorkItem { [weak self] in
            self?.replyWithCurrentSnapshot()
        }
        self.timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + renderTimeout, execute: timeout)

        webView.loadHTMLString(html, baseURL: baseURL)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "qlThumbnailReady",
              let dataURI = message.body as? String else { return }
        replyWithDataURI(dataURI)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        replyWithError(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        replyWithError(error)
    }

    // MARK: - Reply paths

    private func replyWithDataURI(_ uri: String) {
        guard !didReply else { return }
        didReply = true
        timeoutWorkItem?.cancel()

        // Data URI format: "data:image/png;base64,XXXX..."
        guard let comma = uri.firstIndex(of: ","),
              let data = Data(base64Encoded: String(uri[uri.index(after: comma)...]),
                              options: .ignoreUnknownCharacters),
              let image = NSImage(data: data) else {
            replyWithError(NSError(domain: "QuickLookProtein.Thumbnail", code: 3,
                                   userInfo: [NSLocalizedDescriptionKey: "Could not decode rendered image"]))
            return
        }
        finishWith(image: image)
    }

    /// Fallback when the JS hand-shake never fires: capture whatever the WKWebView has
    /// drawn so far. May return an empty image — we accept that over hanging.
    private func replyWithCurrentSnapshot() {
        guard !didReply else { return }
        didReply = true
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
        let reply = QLThumbnailReply(contextSize: size) { ctx -> Bool in
            // Center the image in the requested context, preserving aspect ratio.
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
}
