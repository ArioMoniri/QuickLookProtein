//
//  Updater.swift
//  QuickLookProtein
//
//  Lightweight auto-updater that hits the GitHub Releases REST API on launch
//  (and every 24h after) and, if a newer release exists, presents the user
//  with a "Download" prompt that opens the release page in the browser.
//
//  Rationale: this is a sandboxed Quick Look helper. Sparkle for sandboxed apps
//  requires two XPC service targets, an EdDSA signing key, an appcast.xml, and
//  signing every release with that key. For a small one-developer project,
//  this notify-and-link approach gives the same end-user value with zero
//  infrastructure overhead. If you ever ship through the Mac App Store, remove
//  this file — auto-update prompts that send users off-store are forbidden.
//

import Foundation
import AppKit
import SwiftUI

/// User-facing GitHub repository whose Releases drive the updater.
private let updaterOwner = "ArioMoniri"
private let updaterRepo  = "QuickLookProtein"

/// How often to silently check on app launch.
private let updaterCheckInterval: TimeInterval = 24 * 60 * 60

/// Defaults keys used for state.
private enum UpdaterKey {
    static let lastCheck         = "updater.lastCheck"
    static let skippedVersion    = "updater.skippedVersion"
    static let lastPromptVersion = "updater.lastPromptVersion"
}

struct ReleaseInfo {
    let tag: String          // raw tag like "v1.6" or "1.6"
    let name: String         // user-facing title
    let url: URL             // html_url of the release
    let body: String         // markdown release notes
    let version: (major: Int, minor: Int, patch: Int)
}

@MainActor
final class Updater: ObservableObject {

    static let shared = Updater()

    @Published var latestRelease: ReleaseInfo?
    @Published var isChecking = false
    @Published var lastError: String?

    /// Called once at app start. Performs a silent check unless one ran in the
    /// last 24h, in which case it does nothing until the user picks "Check now".
    func checkOnLaunchIfNeeded() {
        if let last = UserDefaults.standard.object(forKey: UpdaterKey.lastCheck) as? Date,
           Date().timeIntervalSince(last) < updaterCheckInterval {
            return
        }
        check(silent: true)
    }

    /// User-initiated check from the About panel — always runs, surfaces errors.
    func check(silent: Bool) {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil

        Task { [weak self] in
            defer { Task { @MainActor in self?.isChecking = false } }
            do {
                let release = try await self?.fetchLatestRelease()
                await MainActor.run {
                    UserDefaults.standard.set(Date(), forKey: UpdaterKey.lastCheck)
                    self?.latestRelease = release
                    if let release = release, self?.isNewer(release) == true {
                        self?.maybePromptForUpdate(release: release, silent: silent)
                    } else if !silent {
                        self?.showAlertOnLatest()
                    }
                }
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    if !silent { self?.showAlertOnError(error) }
                }
            }
        }
    }

    // MARK: - Networking

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(updaterOwner)/\(updaterRepo)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("QuickLookProtein-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Updater", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "GitHub responded with status \((response as? HTTPURLResponse)?.statusCode ?? -1)"])
        }

        struct GitHubRelease: Decodable {
            let tag_name: String
            let name: String?
            let html_url: String
            let body: String?
            let prerelease: Bool
            let draft: Bool
        }
        let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !decoded.draft, !decoded.prerelease else {
            throw NSError(domain: "Updater", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Latest release is a draft / prerelease"])
        }
        guard let url = URL(string: decoded.html_url) else {
            throw NSError(domain: "Updater", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Malformed release URL"])
        }
        let v = parseSemver(decoded.tag_name)
        return ReleaseInfo(tag: decoded.tag_name,
                           name: decoded.name ?? decoded.tag_name,
                           url: url,
                           body: decoded.body ?? "",
                           version: v)
    }

    // MARK: - Version compare

    private func parseSemver(_ s: String) -> (major: Int, minor: Int, patch: Int) {
        let trimmed = s.hasPrefix("v") || s.hasPrefix("V") ? String(s.dropFirst()) : s
        let parts = trimmed.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        return (parts.first ?? 0,
                parts.count > 1 ? parts[1] : 0,
                parts.count > 2 ? parts[2] : 0)
    }

    private func currentVersion() -> (major: Int, minor: Int, patch: Int) {
        guard let s = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return (0, 0, 0)
        }
        return parseSemver(s)
    }

    private func isNewer(_ release: ReleaseInfo) -> Bool {
        let me = currentVersion()
        let them = release.version
        if them.major != me.major { return them.major > me.major }
        if them.minor != me.minor { return them.minor > me.minor }
        return them.patch > me.patch
    }

    // MARK: - UI

    private func maybePromptForUpdate(release: ReleaseInfo, silent: Bool) {
        // Respect "skip this version".
        if let skipped = UserDefaults.standard.string(forKey: UpdaterKey.skippedVersion),
           skipped == release.tag, silent {
            return
        }
        showUpdateAlert(release: release)
    }

    private func showUpdateAlert(release: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "QuickLookProtein \(release.tag) is available"
        let bodyExcerpt = release.body
            .split(whereSeparator: \.isNewline)
            .prefix(8)
            .joined(separator: "\n")
        alert.informativeText = bodyExcerpt.isEmpty
            ? "A new version is available. Would you like to open the download page?"
            : bodyExcerpt
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Remind Me Later")
        alert.addButton(withTitle: "Skip This Version")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.url)
        case .alertSecondButtonReturn:
            break
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.tag, forKey: UpdaterKey.skippedVersion)
        default:
            break
        }
    }

    private func showAlertOnLatest() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "QuickLookProtein is already the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showAlertOnError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Couldn't check for updates"
        alert.runModal()
    }
}
