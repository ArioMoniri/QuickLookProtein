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
                // Original was 800×600 with 3 tiles + a short About. We now have
                // 5 tiles in a row and a richer About panel; 1100×720 keeps each
                // tile roughly the same on-screen size as the upstream app while
                // leaving the About column readable.
                .frame(minWidth: 1100, idealWidth: 1100, minHeight: 720, idealHeight: 720)
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
