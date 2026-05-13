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

    /// Implicitly unwrapped because we can't pass `self` to
    /// `SPUStandardUpdaterController.init(updaterDelegate:)` until after
    /// `super.init()` has run; Sparkle 2.x's `SPUUpdater.delegate` is
    /// read-only so we have to set the delegate at construction time, not
    /// afterwards.
    private var controller: SPUStandardUpdaterController!

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
        // `startingUpdater: true` means Sparkle starts its scheduled-check
        // timer immediately; the SUEnableAutomaticChecks /
        // SUScheduledCheckInterval Info.plist keys control its cadence.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    /// Wired to the "Check for Updates…" menu item and the About-panel button.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
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
