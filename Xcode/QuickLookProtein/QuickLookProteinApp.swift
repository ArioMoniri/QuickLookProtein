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
                // Scrollable settings column up top (capped at 360 px) +
                // previews row with a 320 px minimum + a divider + padding.
                // 1100×760 gives everything natural room; the user can grow
                // the window from there.
                .frame(minWidth: 1080, idealWidth: 1180, minHeight: 740, idealHeight: 780)
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
