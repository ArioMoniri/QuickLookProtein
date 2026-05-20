//
//  QuickLookProteinApp.swift
//  QuickLookProtein
//
//  Created by Jethro Hemmann on 15.08.21.
//

import SwiftUI
import AppKit

// https://stackoverflow.com/questions/65743619/close-swiftui-application-when-last-window-is-closed
class AppDelegate: NSObject, NSApplicationDelegate {

    /// Default content size the window opens at on every launch. SwiftUI's
    /// `.frame(idealWidth:idealHeight:)` is just a hint and macOS frequently
    /// restores a previously-resized frame from `NSWindow` saved state, which
    /// is why the user kept seeing the app open near-fullscreen. We override
    /// here so every launch starts from the same compact size.
    private let defaultWindowSize = NSSize(width: 940, height: 720)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wait one runloop turn so SwiftUI has time to create the window.
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let window = NSApp.windows.first(where: { $0.contentView != nil }) else { return }
            // Disable frame autosave so a previous user-resize doesn't
            // override the default size on the next launch.
            window.setFrameAutosaveName("")
            window.setContentSize(self.defaultWindowSize)
            window.center()
        }
    }

    // close app completely after window has been closed
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
         return true
    }
}

@main
struct QuickLookProteinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                // Content min-size only — the actual launch window size is
                // forced by AppDelegate.applicationDidFinishLaunching so saved
                // frame state can't grow the window. Without a maxWidth/Height,
                // the user can still resize freely.
                .frame(minWidth: 720, minHeight: 560)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                    // Sparkle's SPUStandardUpdaterController starts its scheduled-check
                    // timer in its initializer (referenced via Updater.shared); we just
                    // need to touch it to keep the singleton alive.
                    _ = Updater.shared
                }
        }
        .commands {
            CommandGroup(replacing: .newItem, addition: {}) // remove File -> New Window from menu
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Updater.shared.checkForUpdates()
                }
            }
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
         return true
    }
}
