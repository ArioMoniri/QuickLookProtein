//
//  Updater.swift
//  QuickLookProtein
//
//  Sparkle 2.x integration for in-place auto-updates. Replaces the previous
//  GitHub-Releases-API checker so users get the standard "Install Update"
//  dialog that downloads, verifies, and relaunches the app — no manual
//  redownload step.
//
//  Build modes:
//    - With Sparkle SPM dependency present (the normal release build),
//      `canImport(Sparkle)` is true and this file wires up the real updater.
//    - Without Sparkle (e.g. a quick local development build where you
//      haven't yet added the SPM dep), the file compiles to a no-op stub
//      that opens the Releases page in the browser, so the rest of the
//      app still builds.
//
//  Setup (one-time, see docs/SPARKLE_SETUP.md):
//    1. In Xcode: File → Add Package Dependencies → paste
//       https://github.com/sparkle-project/Sparkle → "Up to Next Major"
//       from 2.6.0 → add the Sparkle library product to the
//       QuickLookProtein target.
//    2. Run scripts/generate-sparkle-keys.sh to produce a public key.
//    3. Paste the public key into Info.plist under SUPublicEDKey.
//    4. Put the private key (base64) into the GitHub Actions secret
//       `SPARKLE_ED_PRIVATE_KEY`.
//

import Foundation
import AppKit
import SwiftUI

#if canImport(Sparkle)
import Sparkle

/// Thin SwiftUI-friendly wrapper around Sparkle's `SPUStandardUpdaterController`.
/// Publishes the small slice of state the About panel cares about so the UI
/// can surface "checking…" / "up to date" / "update available" without
/// subclassing any Sparkle types.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {

    static let shared = Updater()

    @Published var canCheck: Bool = true
    @Published var lastCheckStatus: String = ""
    /// Honest signal of whether Sparkle actually came up. UI uses this to
    /// avoid showing the "Your software is up to date" hero when in fact
    /// the controller never started (placeholder key, signing mismatch,
    /// stale install, etc.).
    @Published var sparkleAvailable: Bool = false
    /// Set when `sparkleAvailable == false`, this is the human-readable
    /// reason — surfaced inline in the About / Software Update panel so
    /// the user can fix it (or do a manual download) without spelunking
    /// Console.app.
    @Published var sparkleUnavailableReason: String = ""

    /// Two real Sparkle knobs surfaced as @Published proxies so the
    /// Settings UI's Software Update panel can bind directly. Setting
    /// either property writes the change back to SPUUpdater immediately
    /// and Sparkle persists the value via its own NSUserDefaults storage.
    @Published var automaticallyChecksForUpdates: Bool = true {
        didSet {
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    /// Cadence is stored in seconds; expose as a Picker-friendly enum.
    @Published var updateCheckCadence: UpdateCheckCadence = .weekly {
        didSet {
            controller?.updater.updateCheckInterval = updateCheckCadence.seconds
        }
    }

    enum UpdateCheckCadence: String, CaseIterable, Identifiable {
        case daily   = "Daily"
        case weekly  = "Weekly"
        case monthly = "Monthly"
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .daily:   return 60 * 60 * 24
            case .weekly:  return 60 * 60 * 24 * 7
            case .monthly: return 60 * 60 * 24 * 30
            }
        }
        static func from(seconds: TimeInterval) -> UpdateCheckCadence {
            if seconds <= 60 * 60 * 24 * 2          { return .daily }
            if seconds <= 60 * 60 * 24 * 14         { return .weekly }
            return .monthly
        }
    }

    /// Optional because we only construct Sparkle when `SUPublicEDKey`
    /// in Info.plist is a real key — not the `REPLACE_WITH_…` placeholder
    /// the source ships with. Constructing `SPUStandardUpdaterController`
    /// against the placeholder makes Sparkle log
    ///     "Fatal updater error (1): The EdDSA public key is not valid"
    /// on every app launch even before the user touches any UI.
    private var controller: SPUStandardUpdaterController?

    /// Stable shared formatter — `Date.formatted(date:time:)` is macOS 12+,
    /// but the project's deployment target is 11. DateFormatter is fine on
    /// every supported version and cheap to keep alive as a singleton.
    private static let lastCheckFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    override private init() {
        super.init()
        // Only spin up Sparkle when we have a real public key to verify
        // signatures against. Otherwise Sparkle errors on every launch.
        guard self.sparkleIsConfigured else {
            self.sparkleAvailable = false
            self.sparkleUnavailableReason =
                "Sparkle public key isn't set in this build — auto-updates are disabled. Use Download from GitHub to grab the latest signed DMG."
            return
        }

        // CRITICAL: pass startingUpdater:false. The `true` variant calls
        // SPUUpdater.startUpdater() synchronously inside init and routes
        // any thrown error to SPUStandardUserDriver, which presents the
        // stock "Updater failed to start. Please verify you have the
        // latest version…" modal BEFORE our app's UI is even on screen
        // (1.7.45+ fix for the persistent user complaint where the alert
        // appeared on every launch of correctly-installed builds with
        // valid Sparkle configuration).
        //
        // Instead we construct the controller without auto-starting,
        // then call startUpdater(_:) ourselves below, capturing any
        // error into lastCheckStatus so the About panel shows what
        // failed without blocking the user with a modal.
        let ctl = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        do {
            try ctl.updater.start()
            self.controller = ctl
            // Reflect Sparkle's persisted settings into our @Published
            // proxies so the UI starts in sync. didSets are intentionally
            // bypassed here — assigning the same value would re-write to
            // Sparkle and noop, but doing it through `_` keeps the
            // direction-of-truth one-way from Sparkle to UI on startup.
            self.automaticallyChecksForUpdates = ctl.updater.automaticallyChecksForUpdates
            self.updateCheckCadence = UpdateCheckCadence.from(seconds: ctl.updater.updateCheckInterval)
            self.lastCheckStatus = "Auto-updates enabled."
            self.sparkleAvailable = true
        } catch {
            // Sparkle's start() throws for malformed SUPublicEDKey, bad
            // feed URL, XPC handshake failure, etc. Don't show a modal —
            // log to the About panel, and fall back to the manual-update
            // path (which opens the GitHub Releases page in the browser).
            self.controller = nil
            self.sparkleAvailable = false
            self.sparkleUnavailableReason =
                "Sparkle couldn't start: \(error.localizedDescription). This usually means the installed app is too old to auto-update through the v1.7.45+ fix. One manual DMG download from GitHub will fix it permanently."
            self.lastCheckStatus = "Auto-updates unavailable — see Software Update for details."
        }
    }

    /// Bundle.main URL for the public-on-github releases page — used as the
    /// fallback when Sparkle is unusable in the current build (placeholder
    /// public key, missing feed, etc.).
    private let releasesURL = URL(string: "https://github.com/ArioMoniri/QuickLookProtein/releases/latest")!

    /// The Info.plist key ships with a well-formed but functionally bogus
    /// zero-byte EdDSA placeholder until the user runs
    /// `scripts/generate-sparkle-keys.sh` (or the release workflow injects
    /// the real key from secrets). We detect both the zero-key placeholder
    /// and the legacy `REPLACE_WITH_…` text placeholder so old Info.plists
    /// still light up the fallback path. When a real key is present we let
    /// Sparkle take over.
    private var sparkleIsConfigured: Bool {
        guard let rawKey = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String else {
            return false
        }
        // Trim accidental whitespace/newlines that CI secret-injection
        // sometimes leaves on the value (we've seen trailing \n on a
        // few configurations). Without trimming, key.count == 44 fails
        // even though the actual bytes are correct.
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              !key.hasPrefix("REPLACE_WITH_"),
              key != Self.zeroEdDSAPlaceholder else {
            return false
        }
        // A valid Ed25519 public key in base64 is exactly 44 chars: 32 raw
        // bytes → 43 base64 chars + 1 padding "=". Anything else gets
        // rejected here rather than during SPUUpdater.start() (which would
        // throw a less-helpful error).
        guard key.count == 44, key.hasSuffix("=") else {
            return false
        }
        return true
    }

    /// Base64 encoding of 32 zero bytes — the well-formed but functionally
    /// bogus Ed25519 public key the source ships with. See Info.plist
    /// comment for why we use a decodable placeholder rather than a
    /// human-readable one.
    private static let zeroEdDSAPlaceholder = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    /// Wired to the "Check for Updates…" menu item and the About-panel button.
    func checkForUpdates() {
        guard let controller = controller else {
            lastCheckStatus = "Sparkle public key not set — opening release page in browser."
            NSWorkspace.shared.open(releasesURL)
            return
        }
        lastCheckStatus = "Checking…"
        controller.checkForUpdates(nil)
    }

    /// Open the GitHub Releases page in the user's default browser —
    /// fallback when Sparkle isn't configured (no public key) or when
    /// the user clicks "Download from GitHub" deliberately.
    func openReleasesPage() {
        NSWorkspace.shared.open(releasesURL)
    }

    /// Reset macOS's Quick Look generator cache. Run when the QL preview
    /// stops refreshing after an update (the system caches the old
    /// extension's bundle path until restarted).
    func resetQuickLookCache() {
        let p = Process()
        p.launchPath = "/usr/bin/qlmanage"
        p.arguments = ["-r", "cache"]
        do {
            try p.run()
            p.waitUntilExit()
            // Also reset the registered generator list so the new
            // extension version gets picked up.
            let q = Process()
            q.launchPath = "/usr/bin/qlmanage"
            q.arguments = ["-r"]
            try q.run()
            q.waitUntilExit()
            lastCheckStatus = "Quick Look cache reset (\(Self.lastCheckFormatter.string(from: Date())))."
        } catch {
            lastCheckStatus = "qlmanage failed: \(error.localizedDescription)"
        }
    }

    // MARK: SPUUpdaterDelegate (small lifecycle pings the About UI surfaces)

    nonisolated func updater(_ updater: SPUUpdater,
                             didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: Error?) {
        let now = Date()
        Task { @MainActor in
            if let error = error {
                self.lastCheckStatus = "Update check failed: \(error.localizedDescription)"
            } else {
                self.lastCheckStatus = "Last check: \(Updater.lastCheckFormatter.string(from: now))"
            }
        }
    }

    nonisolated func updaterMayCheck(forUpdates updater: SPUUpdater) -> Bool { true }
}

#else

// ----- Fallback stub when Sparkle SPM isn't yet added in Xcode. -----------
//
// Keeps the rest of the app compiling (and behaving sensibly) so a fresh
// `git clone` doesn't fail to build before the user adds the SPM dependency.
// In this mode "check for updates" just opens the Releases page in the
// browser.

@MainActor
final class Updater: ObservableObject {

    static let shared = Updater()

    @Published var canCheck: Bool = true
    @Published var lastCheckStatus: String =
        "Sparkle SPM not yet added — see docs/SPARKLE_SETUP.md. Falling back to web."

    private init() {}

    func checkForUpdates() {
        if let url = URL(string: "https://github.com/ArioMoniri/QuickLookProtein/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }
}

#endif
