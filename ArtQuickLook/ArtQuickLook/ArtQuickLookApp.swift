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
    
    /// Drives menu validation. Window key-status changes are observed natively
    /// (DocumentFocusModel) and re-render the scene tree — commands included.
    @StateObject private var documentFocus = DocumentFocusModel.shared
    
    var body: some Scene {
        // Module-qualified on purpose: this target also declares a config
        // struct named `Settings`, which shadows SwiftUI's scene. A bare
        // `Settings { … }` resolves to that struct — not a Scene — and fails
        // to compile with "Extra trailing closure passed in call" and
        // "Value of type 'Settings' has no member 'commands'".
        SwiftUI.Settings {
            SettingsSceneContent()
        }
        
        // Restores the full default menu bar (Quit/Hide/Services, Edit,
        // Window with its tab commands, Help) that a Settings-only scene
        // does not get. Its auto-created window is a launcher that closes
        // itself immediately — this app starts windowless by design.
        WindowGroup("ArtQuickLook") {
            DocumentHomeView()
        }
        .commands {
            AppMenuBar(documentIsFocused: documentFocus.hasFocusedDocument)
        }
    }
}

// MARK: - WindowGroup content (document launcher)

/// The WindowGroup exists primarily to bring back the full default menu bar;
/// its window doubles as a launcher for documents. Because the app must
/// start windowless, the auto-created instance closes itself the moment its
/// content is live (see `HomeWindowCloser`).
struct DocumentHomeView: View {
    /// `true` (default): the app starts windowless — the auto-created home
    /// window closes itself (drag a file onto the Dock icon, or ⌘O, instead).
    /// `false`: keep the window visible as an "Open…" launcher at start.
    static var suppressAutoCreatedWindow = false
    
    var body: some View {
        VStack(spacing: 14) {
            Text("ArtQuickLook")
                .font(.title2.weight(.semibold))
            Text("Drop a .art file onto the Dock icon, or open one directly.")
                .foregroundStyle(.secondary)
            Button("Open .art File…") { AppMenuBar.openArtDocument() }
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 240)
        .background(HomeWindowCloser())
    }
}

/// Attached to DocumentHomeView; closes the hosting window as soon as the
/// view lands in it. With no "New Window" command in the menu, every home
/// window is an auto-created one (launch, state restore, or a stray
/// SwiftUI-spawned window on a document event), so closing on attach is
/// always correct while the flag above is set.
private struct HomeWindowCloser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AutoCloseView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    final class AutoCloseView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window = self.window,
                  DocumentHomeView.suppressAutoCreatedWindow else { return }
            // Async: never close midway through window setup.
            DispatchQueue.main.async { window.close() }
        }
    }
}

// MARK: - Settings scene content

/// ContentView inside the Settings scene, plus a tag that keeps the settings
/// window out of every tab group (this used to live in
/// `AppDelegate.showSettingsWindow()`, which no longer exists).
struct SettingsSceneContent: View {
    var body: some View {
        ContentView()
            .background(SettingsWindowTagger())
    }
}

private struct SettingsWindowTagger: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TaggerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    final class TaggerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.window?.tabbingMode = .disallowed
        }
    }
}

// MARK: - Menu commands

struct AppMenuBar: Commands {
    let documentIsFocused: Bool
    
    var body: some Commands {
        // File: drop "New", add the document opener.
        CommandGroup(replacing: .newItem) {
            Button("Open .art-file…") { Self.openArtDocument() }
                .keyboardShortcut("o")
        }
        
        // View: the live view's resets, for the focused document window.
        //
        // Shortcut notes:
        // - The old ⇧-only equivalents ("⇧P", "⇧Z", "⇧R") were ambiguous: SwiftUI
        //   matched them without Shift held, so resets fired on bare key presses.
        //   Every equivalent now includes ⌘, which matches strictly.
        // - ⌘0 is the convention for "reset zoom" (browsers, image viewers), so
        //   zoom gets it; "reset everything" moves to ⇧⌘0.
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Reset View") { LiveMTKView.resetFocused(.all) }
                .keyboardShortcut("0", modifiers: [.command, .shift])
                .disabled(!documentIsFocused)
            Button("Reset Pan") { LiveMTKView.resetFocused(.pan) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!documentIsFocused)
            Button("Reset Zoom") { LiveMTKView.resetFocused(.zoom) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!documentIsFocused)
            Button("Reset Rotation") { LiveMTKView.resetFocused(.rotation) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!documentIsFocused)
        }
        
        // No custom app-menu group. SwiftUI installs "About ArtQuickLook" and
        // "Preferences… ⌘," (wired to the Settings scene) automatically; adding
        // our own Preferences button either duplicates it or, if .appInfo is
        // replaced, removes the working one.
    }
    
    /// `NSOpenPanel` rather than SwiftUI's `.fileImporter`, which has no menu-command
    /// equivalent; documents land in a `DocumentWindowCoordinator` window either way.
    /// Internal (not private): DocumentHomeView's "Open…" button reuses it.
    static func openArtDocument() {
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

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    
    // MARK: Documents — the one and only document path, restored verbatim
    
    /// Open-document Apple events (Finder, Quick Look hand-off, `open`, dock
    /// drops, Open With…). This was working and is back to being the primary
    /// path — no Apple-event interception. `DocumentWindowCoordinator` dedupes
    /// by URL. (Any `.onOpenURL` in ContentView is now redundant; it can no
    /// longer trigger window creation since there is no WindowGroup, but
    /// removing it keeps the pipeline single-sourced.)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { DocumentWindowCoordinator.shared.open(url: url) }
    }
    
    // MARK: Reopen (dock icon, `open -a`, Spotlight)
    
    /// Desired behaviour: clicking the Dock icon while no windows are open
    /// shows nothing — no settings window, no home window. Returning false
    /// owns the windowless reopen and blocks both AppKit's and SwiftUI's
    /// default "create/reopen a WindowGroup window" path.
    ///
    /// A document Apple event that follows (drag onto the Dock icon, Open
    /// With…) is delivered to application(_:open:) independently of this
    /// return value, so document opens are unaffected.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            return true        // windows exist: default activation is fine
        }
        return false           // windowless: stay windowless by design
    }
    
    // MARK: Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Document windows auto-tab (they opt in with `.preferred` plus a shared
        // tabbingIdentifier). Without this, the system default ("Prefer tabs:
        // In Full Screen") keeps document windows from ever tabbing. The
        // Settings window is tagged .disallowed by SettingsWindowTagger.
        NSWindow.allowsAutomaticWindowTabbing = true
        
        // Nothing else: no settings window at launch, and the WindowGroup's
        // auto-created home window closes itself (DocumentHomeView), so the
        // app starts windowless — matching the requested behaviour.
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false                              // Quick Look companion: stay alive
    }
    
}

