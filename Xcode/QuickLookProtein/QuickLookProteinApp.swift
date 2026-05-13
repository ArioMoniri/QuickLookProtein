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
                // Bumped from 800×600 — with the additional formats and the
                // drag-drop tile, the previews row needs more horizontal room,
                // and the richer settings column wants the extra height.
                .frame(minWidth: 1100, idealWidth: 1100, minHeight: 720, idealHeight: 720)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                }
        }
        .commands {
            CommandGroup(replacing: .newItem, addition: {}) // remove File -> New Window from menu
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
         return true
    }
}
