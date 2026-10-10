//
//  ArtQuickLookApp.swift
//  ArtQuickLook
//
//  Created by memileo on 2025-10-24.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

    /// Keeps the settings window a singleton on macOS 12, where `Window` (the natural
    /// singleton scene) does not exist and `WindowGroup` will happily make a second one.
    /// Returning true makes a reopen *activate* the running window instead of opening
    /// another, so `open -a ArtQuickLook` can never stack settings windows.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows {
            NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

struct Menu: Commands {
    var body: some Commands {
        CommandMenu("File") {
            Button("Open .art-file…") { openArtDocument() }
                .keyboardShortcut("o")
        }
    }

    /// `NSOpenPanel` rather than SwiftUI's `.fileImporter`, which has no menu-command
    /// equivalent; documents land in a `DocumentWindowCoordinator` window either way.
    private func openArtDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a Mischief .art document"
        panel.allowedContentTypes = [UTType(filenameExtension: "art") ?? .data]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DocumentWindowCoordinator.shared.open(url: url)
        }
    }
}
