//
//  LoginItem.swift
//  QuickLookProtein
//
//  macOS Open-at-Login control (1.7.75+). Wraps SMAppService so the
//  Settings UI can flip "launch this app when the user signs in"
//  without diving into the System Settings app or shipping a
//  separate LaunchAgent .plist.
//
//  Why this lives in the main app target and not Settings.swift:
//  - SMAppService.mainApp is only meaningful for the .app bundle
//    that actually wants to be re-launched at login; the QL extension
//    and Spotlight indexer are not standalone-launchable.
//  - ServiceManagement.framework is macOS-13-only for the modern
//    SMAppService API.  Older macOS (11, 12) falls back to a
//    deep-link into System Settings -> General -> Login Items so the
//    user can flip the toggle there.  We don't ship a separate
//    LaunchAgent for the legacy path - the deep-link is honest and
//    one extra click for a small fraction of users.
//

import Foundation
import AppKit
import ServiceManagement
import os.log

@available(macOS 11.0, *)
final class LoginItemController: ObservableObject {

    static let shared = LoginItemController()

    private let log = OSLog(subsystem: "com.ariomoniri.QuickLookProtein",
                            category: "LoginItem")

    /// Mirrors the runtime state of the app's Login Items
    /// registration.  Updated on each register/unregister call and
    /// refreshed on app foregrounding.
    @Published var isEnabled: Bool = false

    /// True when the system supports the modern SMAppService API
    /// (macOS 13+). On older systems we fall back to opening the
    /// Login Items pane in System Settings.
    var isAutomaticToggleSupported: Bool {
        if #available(macOS 13.0, *) { return true } else { return false }
    }

    private init() {
        refresh()
    }

    /// Re-read the system state. Cheap, can be called from
    /// applicationDidBecomeActive to keep the UI in sync if the
    /// user flipped the toggle in System Settings while our app
    /// was backgrounded.
    func refresh() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            self.isEnabled = (status == .enabled)
            os_log("LoginItem refresh: status=%{public}@",
                   log: log, type: .info,
                   String(describing: status))
        } else {
            // Pre-13 we have no API to query LSSharedFileList from a
            // sandboxed app, so assume off.  The user can confirm via
            // System Preferences > Users & Groups > Login Items.
            self.isEnabled = false
        }
    }

    /// Toggle Open-at-Login. On macOS 13+ this flips it via
    /// SMAppService; on older macOS it opens the Login Items pane
    /// in System Settings so the user can do it themselves.
    func setEnabled(_ desired: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if desired {
                    try SMAppService.mainApp.register()
                    os_log("SMAppService.mainApp.register() succeeded", log: log, type: .info)
                } else {
                    try SMAppService.mainApp.unregister()
                    os_log("SMAppService.mainApp.unregister() succeeded", log: log, type: .info)
                }
                refresh()
            } catch {
                os_log("SMAppService register/unregister failed: %{public}@",
                       log: log, type: .error,
                       error.localizedDescription)
                // Revert UI to actual state on failure.
                refresh()
            }
        } else {
            openSystemSettingsLoginItems()
        }
    }

    /// Deep-link into the user-facing Login Items pane. Works
    /// on all supported macOS versions; the URL scheme has been
    /// stable since Big Sur even though the pane itself moved
    /// between "System Preferences" and "System Settings" in
    /// macOS 13.
    func openSystemSettingsLoginItems() {
        let urls = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.users?LoginItems",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) {
                return
            }
        }
        // Last-ditch fallback if the URL schemes ever break.
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
    }
}
