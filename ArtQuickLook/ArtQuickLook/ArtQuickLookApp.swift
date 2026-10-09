//
//  ArtQuickLookApp.swift
//  ArtQuickLook
//
//  Created by memileo on 2025-10-24.
//

import SwiftUI

@main
struct ArtQuickLookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    var body: some Scene {
        // `Window` is macOS 13+, so on 12 this has to be a WindowGroup.
        // Relaunching the bundle only activates the running instance, and the
        // File ▸ New item is removed below, so there's still only one settings
        // window in practice.
        WindowGroup("ArtQuickLook Settings") {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            Menu()
        }
        
        // Document windows: `WindowGroup(id:for:)` + `openWindow` are macOS 13+,
        // so documents open as plain NSWindows managed by
        // DocumentWindowCoordinator. Still one window per document, still the
        // profileable process you point Instruments at.
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Open-document Apple events (Finder, Quick Look hand-off, `open`).
    // onOpenURL in ContentView also fires; the coordinator dedupes by URL.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { DocumentWindowCoordinator.shared.open(url: url) }
    }
}

struct Menu: Commands {
    var body: some Commands {
        CommandMenu("File") {
            Button("Open .art-file...") {
                print("menu1")
            }
        }
    }
}
