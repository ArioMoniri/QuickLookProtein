//
//  ThumbnailProvider.swift
//  QLThumbnail
//
//  Generates per-file Finder thumbnails for molecular structure files.
//
//  Why this is pure Cocoa drawing (no WKWebView, no 3Dmol.js):
//
//      The original implementation hosted a WKWebView inside an off-screen
//      NSWindow and snapshotted its WebGL canvas after 3Dmol.js finished
//      rendering. That worked on macOS 11–13, but macOS 14+ sandboxed
//      thumbnail extensions are blocked from talking to `com.apple.dock.
//      fullscreen` and `com.apple.windowmanager.server` — the os_log dump
//      from a hung request shows
//          denied lookup: name = com.apple.dock.fullscreen ... error = 159
//          PageClientImpl isViewVisible(): viewWindow 0x0, window occluded 1
//      WebKit then refuses to paint the layer tree because there's no
//      visible window, 3Dmol never finishes initialising, the 5.5 s
//      timeout fires, and Finder shows the generic doc icon.
//
//      Workarounds we tried that don't work: alphaValue=0.01 windows
//      (still need window-server access to make-key), CALayer-only render
//      pipelines (WebKit's compositor short-circuits on occluded windows),
//      `WKSnapshotConfiguration(afterScreenUpdates: false)` (Web process
//      hasn't even allocated a backing store).
//
//      Pragmatic fix: skip WebView for thumbnails. Draw a static "atom"
//      glyph + format label entirely with Core Graphics — sandbox-safe,
//      runs in <10 ms, never times out. The actual 3D molecule is still
//      rendered for *previews* (Space-bar / right-pane), which use the
//      QLPreviewingController code path where the WebView lives inside
//      the system-provided preview window and the sandbox lets WebKit
//      paint normally.
//
//      Bonus: we no longer need to bundle 3Dmol.js (~1.8 MB) or the
//      viewer template inside the .appex.
//

import Cocoa
import QuickLookThumbnailing
import os.log

/// Subsystem-tagged logger — paired with QLExtension's. Stream messages from
/// both Quick Look surfaces with:
///     log show --info --predicate 'subsystem BEGINSWITH "com.jethrohemmann.QuickLookProtein"' --last 2m
private let thumbLog = OSLog(subsystem: "com.jethrohemmann.QuickLookProtein.QLThumbnail",
                             category: "thumbnail")

// The @objc attribute is load-bearing: NSExtensionPrincipalClass in our
// Info.plist points at "QLThumbnailThumbnailProvider" and PluginKit looks
// the class up via NSClassFromString. Without it the Swift name gets
// mangled (e.g. _TtC11QLThumbnail17ThumbnailProvider) and PluginKit
// silently fails to register the extension.
@objc(QLThumbnailThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {

        let ext = request.fileURL.pathExtension.lowercased()
        let size = request.maximumSize
        os_log("provideThumbnail called for %{public}@ (ext=%{public}@, size=%{public}.0fx%{public}.0f)",
               log: thumbLog, type: .info, request.fileURL.path, ext, size.width, size.height)

        // We don't actually need to read the file — the drawn icon is the
        // same per-format. Validating the extension is enough; an unknown
        // extension shouldn't have routed to us, but if it did we hand it
        // back so Finder picks a default.
        guard Self.supportedExtensions.contains(ext) else {
            os_log("Unsupported extension .%{public}@ — declining", log: thumbLog, type: .info, ext)
            handler(nil, nil)
            return
        }

        let reply = QLThumbnailReply(contextSize: size) { _ -> Bool in
            Self.drawAtomGlyph(ext: ext, in: NSRect(origin: .zero, size: size))
            return true
        }
        os_log("returning drawn thumbnail (ext=%{public}@)", log: thumbLog, type: .info, ext)
        handler(reply, nil)
    }

    // MARK: - Static configuration

    /// The set of extensions our QL extension handles. Matches the UTI list
    /// in our Info.plist's QLSupportedContentTypes; if the system routes a
    /// file with a different extension to us, we decline cleanly rather
    /// than draw a misleading icon.
    private static let supportedExtensions: Set<String> = [
        "pdb", "ent", "pdbqt", "pqr",
        "cif", "mmcif",
        "sdf", "mol", "mol2",
        "xyz",
        "gro",
        "cube", "cub",
        "vasp", "poscar",
        "cdjson", "json",
        "mmtf",
        "prmtop", "top"
    ]

    /// Per-format ribbon colour. Picked so PDB/CIF (proteins) read as
    /// "protein-y" blue/purple, small molecules as warm tones, and crystal
    /// formats as cool greens — easy to skim in a Finder column at a glance.
    private static let formatColors: [String: NSColor] = [
        "pdb":    .systemBlue,    "ent":    .systemBlue,    "pdbqt":  .systemTeal,
        "pqr":    .systemIndigo,
        "cif":    .systemPurple,  "mmcif":  .systemPurple,
        "sdf":    .systemOrange,
        "mol":    .systemOrange,  "mol2":   .systemRed,
        "xyz":    .systemYellow,
        "gro":    .systemMint,
        "cube":   .systemGray,    "cub":    .systemGray,
        "vasp":   .systemGreen,   "poscar": .systemGreen,
        "cdjson": .systemBrown,   "json":   .systemBrown,
        "mmtf":   .systemBlue,
        "prmtop": .systemPink,    "top":    .systemPink
    ]

    // MARK: - Drawing

    /// Draw an atom-and-bonds glyph plus the format label centred in the
    /// given rect. Designed to look readable at every Finder icon size from
    /// 16×16 (list view) up to 512×512 (icon-view large).
    private static func drawAtomGlyph(ext: String, in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let w = rect.width
        let h = rect.height
        let s = min(w, h)
        let cx = rect.midX
        let cy = rect.midY + s * 0.06  // shift glyph up to leave room for label

        // Dark background — readable against both light and dark Finder
        // chrome. Use a subtle gradient so the icon doesn't read as flat.
        let bg = NSGradient(starting: NSColor(white: 0.15, alpha: 1.0),
                            ending:   NSColor(white: 0.08, alpha: 1.0))
        bg?.draw(in: rect, angle: -90)

        // Central atom + three peripheral atoms. Bond lines drawn first so
        // the spheres overlap them.
        let centerR = s * 0.14
        let outerR  = s * 0.085
        let bondLen = s * 0.26

        let accent = formatColors[ext] ?? .systemBlue
        let peripherals: [(angle: CGFloat, color: NSColor)] = [
            (.pi *  0.40, accent),
            (.pi *  1.10, .white),
            (.pi *  1.75, accent.blended(withFraction: 0.4, of: .white) ?? accent)
        ]

        // Bonds — soft white cylinders with rounded caps so they read as
        // stick bonds rather than wireframe lines.
        ctx.setStrokeColor(NSColor(white: 0.75, alpha: 1.0).cgColor)
        ctx.setLineWidth(s * 0.055)
        ctx.setLineCap(.round)
        for p in peripherals {
            let px = cx + cos(p.angle) * bondLen
            let py = cy + sin(p.angle) * bondLen
            ctx.move(to: CGPoint(x: cx, y: cy))
            ctx.addLine(to: CGPoint(x: px, y: py))
        }
        ctx.strokePath()

        // Peripheral atoms
        for p in peripherals {
            let px = cx + cos(p.angle) * bondLen
            let py = cy + sin(p.angle) * bondLen
            let r = outerR
            drawSphere(ctx: ctx, center: CGPoint(x: px, y: py), radius: r,
                       baseColor: p.color)
        }

        // Central atom — slightly larger, accent-tinted so the user can
        // tell the formats apart in column view.
        drawSphere(ctx: ctx, center: CGPoint(x: cx, y: cy), radius: centerR,
                   baseColor: accent)

        // Format label — bottom-centred. Only drawn at sizes where the text
        // would actually be legible.
        if s >= 64 {
            let label = ext.uppercased() as NSString
            let fontSize = max(s * 0.13, 9)
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
                .kern: fontSize * 0.04
            ]
            let textSize = label.size(withAttributes: attrs)
            let textOrigin = NSPoint(x: (w - textSize.width) / 2,
                                     y: rect.minY + s * 0.06)
            label.draw(at: textOrigin, withAttributes: attrs)
        }
    }

    /// Draw a sphere with a soft highlight so the atom reads as 3D at a
    /// glance. Cheaper than a real shaded render and looks identical at
    /// thumbnail resolution.
    private static func drawSphere(ctx: CGContext, center: CGPoint, radius: CGFloat,
                                   baseColor: NSColor) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)

        // Base fill — slight gradient (darker on the lower-right, brighter
        // upper-left) so the sphere has depth without needing real lighting.
        let dark   = baseColor.blended(withFraction: 0.35, of: .black) ?? baseColor
        let bright = baseColor.blended(withFraction: 0.25, of: .white) ?? baseColor
        let gradient = NSGradient(starting: bright, ending: dark)
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        gradient?.draw(in: rect, angle: -45)
        ctx.restoreGState()

        // Specular highlight — small offset white blob in the upper-left.
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        let hiR = radius * 0.45
        let hiRect = CGRect(x: center.x - radius * 0.4,
                            y: center.y + radius * 0.15,
                            width: hiR * 2, height: hiR * 2)
        let hiGradient = NSGradient(
            starting: NSColor(white: 1.0, alpha: 0.55),
            ending:   NSColor(white: 1.0, alpha: 0.0)
        )
        hiGradient?.draw(in: hiRect, relativeCenterPosition: .zero)
        ctx.restoreGState()
    }
}
