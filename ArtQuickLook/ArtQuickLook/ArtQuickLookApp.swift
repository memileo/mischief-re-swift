//
//  ArtQuickLookApp.swift
//  ArtQuickLook
//
//  Created by memileo on 2025-10-24.
//
//  Scenes
//  ------
//  * `WindowGroup("ArtQuickLook Settings")` — the main window. `Window` (the natural
//    singleton scene) is macOS 13+, and the deployment target is 12, so the singleton
//    behaviour comes from the app delegate instead (`applicationShouldHandleReopen`).
//  * Document windows: `WindowGroup(id:for:)` + `openWindow` are also macOS 13+, so
//    documents open as plain `NSWindow`s managed by `DocumentWindowCoordinator` — one
//    window per document, and a process Instruments can attach to.
//
//  Menus
//  -----
//  Everything goes into the *existing* File/View/App menus via `CommandGroup(replacing:)`.
//  Declaring a `CommandMenu("File")` of your own would add a **second** File menu next to
//  the system one, which is what this used to do.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct ArtQuickLookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("ArtQuickLook Settings") {
            ContentView()
        }
    }
}

// MARK: - Menu commands

struct Menu: Commands {
    var body: some Commands {
        // File: drop "New", add the document opener.
        CommandGroup(replacing: .newItem) {
            Button("Open .art-file…") { openArtDocument() }
                .keyboardShortcut("o")
        }

        // View: the live view's resets, for the focused document window.
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Reset View") { LiveMTKView.resetFocused(.all) }
                .keyboardShortcut("0", modifiers: .control)
                .disabled(!LiveMTKView.hasFocusedDocument)
            Button("Reset Pan") { LiveMTKView.resetFocused(.pan) }
                .keyboardShortcut("p", modifiers: .control)
                .disabled(!LiveMTKView.hasFocusedDocument)
            Button("Reset Zoom") { LiveMTKView.resetFocused(.zoom) }
                .keyboardShortcut("z", modifiers: .control)
                .disabled(!LiveMTKView.hasFocusedDocument)
            Button("Reset Rotation") { LiveMTKView.resetFocused(.rotation) }
                .keyboardShortcut("r", modifiers: .control)
                .disabled(!LiveMTKView.hasFocusedDocument)
        }

        // The app-name menu: "Preferences…" activates the settings window rather than
        // opening a second one (macOS 12 has no `Settings`-scene singleton here).
        CommandGroup(replacing: .appInfo) {
            Button("Preferences…") { activateSettingsWindow() }
                .keyboardShortcut(",", modifiers: .command)
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

    private func activateSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let settings = NSApp.windows.first(where: { $0.title.contains("Settings") }) {
            settings.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - App delegate

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

    /// Dropping a file (or Open With…) hands us a document — that must *not* also bring up
    /// another settings window, which is what `applicationShouldHandleReopen` returning
    /// true used to do for Finder drops.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool,
                                       fileURLs urls: [URL]) -> Bool {
        if !urls.isEmpty {
            for url in urls { DocumentWindowCoordinator.shared.open(url: url) }
        }
        if hasVisibleWindows, urls.isEmpty {
            NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
        }
        return false                       // never open a window for this reopen
    }
}