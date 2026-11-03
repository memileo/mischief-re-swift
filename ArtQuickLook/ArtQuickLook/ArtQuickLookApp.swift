//
//  ArtQuickLookApp.swift
//  ArtQuickLook
//
//  Created by memileo on 2025-10-24.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Entry point

@main
final class AppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()          // stays alive: main() never returns
        app.delegate = delegate
        app.run()
    }
}

// MARK: - Application delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Document windows auto-tab (they opt in via configureAsArtDocument:
        // .preferred + a shared tabbingIdentifier). The system default
        // ("Prefer tabs: In Full Screen") would otherwise never tab them.
        NSWindow.allowsAutomaticWindowTabbing = true
        AppController.shared.showSettingsWindow(nil)
        
        // The menu bar must be in place before the app finishes launching.
        NSApp.mainMenu = AppMenuBuilder.makeMainMenu()
    }
    
    // MARK: Documents — the one and only document path, unchanged
    
    /// Open-document Apple events (Finder, Quick Look hand-off, `open`,
    /// dock drops, Open With…). DocumentWindowCoordinator dedupes by URL.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { DocumentWindowCoordinator.shared.open(url: url) }
    }
    
    // MARK: Reopen (dock icon, `open -a`, Spotlight)
    
    /// Plain AppKit: this return value is actually honoured, so a dock click
    /// with no windows open shows nothing and recreates nothing — no flash.
    /// A document Apple event that follows (dock drop, Open With…) is
    /// delivered to application(_:open:) independently of this value.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // No windows open, show settings window on dock click
            AppController.shared.showSettingsWindow(nil)
            return true
        } else {
            // Windows are open, default activation behavior is fine
            return true
        }
    }
    
    /// Quick Look companion: stay alive with no windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Main menu

enum AppMenuBuilder {
    
    /// The full standard menu bar, built in code (no nib needed).
    ///
    /// Stock items use a nil target so they dispatch through the responder
    /// chain to AppKit's own implementations — that is what brings the
    /// "niceties" back: Services submenu, text-editing commands, ⌘M/Zoom,
    /// the window list, tab management, help. App-specific items (Open…,
    /// Settings…, the resets) target AppController.shared and validate
    /// through it.
    static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        
        // MARK: App menu (About / Settings… / Services / Hide / Quit)
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "ArtQuickLook")
        appItem.submenu = appMenu
        
        add(appMenu, title: "About ArtQuickLook",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        appMenu.addItem(.separator())
        add(appMenu, title: "Settings…",
            action: #selector(AppController.showSettingsWindow(_:)),
            key: ",",  modifiers: .command, target: AppController.shared)
        appMenu.addItem(.separator())
        
        let servicesItem = add(appMenu, title: "Services", action: nil)
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu          // AppKit fills this in
        
        appMenu.addItem(.separator())
        add(appMenu, title: "Hide ArtQuickLook",
            action: #selector(NSApplication.hide(_:)), key: "h", modifiers: .command)
        add(appMenu, title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            key: "h", modifiers: [.command, .option])
        add(appMenu, title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)))
        appMenu.addItem(.separator())
        add(appMenu, title: "Quit ArtQuickLook",
            action: #selector(NSApplication.terminate(_:)), key: "q", modifiers: .command)
        
        // MARK: File menu (Open… / Close)
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        
        add(fileMenu, title: "Open .art File…",
            action: #selector(AppController.openDocument(_:)),
            key: "o",  modifiers: .command, target: AppController.shared)
        add(fileMenu, title: "Open Recent", action: nil, target: nil)
        
        fileMenu.addItem(.separator())
        add(fileMenu, title: "Close",
            action: #selector(NSWindow.performClose(_:)), key: "w",  modifiers: .command)
        
        // MARK: Edit menu (stock text commands via the responder chain)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        
        add(editMenu, title: "Undo", action: Selector(("undo:")), key: "z", modifiers: .command)
        add(editMenu, title: "Redo", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift])
        editMenu.addItem(.separator())
        add(editMenu, title: "Cut", action: #selector(NSText.cut(_:)), key: "x", modifiers: .command)
        add(editMenu, title: "Copy", action: #selector(NSText.copy(_:)), key: "c", modifiers: .command)
        add(editMenu, title: "Paste", action: #selector(NSText.paste(_:)), key: "v", modifiers: .command)
        editMenu.addItem(.separator())
        add(editMenu, title: "Select All", action: #selector(NSText.selectAll(_:)), key: "a", modifiers: .command)
        
        // MARK: View menu (the reset commands, AppKit-validated)
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        
        add(viewMenu, title: "Reset View",
            action: #selector(AppController.resetView(_:)),
            key: "0", target: AppController.shared)
        add(viewMenu, title: "Reset Pan",
            action: #selector(AppController.resetPan(_:)),
            key: "p", modifiers: [.command, .shift], target: AppController.shared)
        add(viewMenu, title: "Reset Zoom",
            action: #selector(AppController.resetZoom(_:)),
            key: "5", target: AppController.shared)
        add(viewMenu, title: "Reset Rotation",
            action: #selector(AppController.resetRotation(_:)),
            key: "r", modifiers: [.command, .shift], target: AppController.shared)
        
        // MARK: Window menu (Minimize / Zoom / Bring All to Front + list)
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        
        add(windowMenu, title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)), key: "m", modifiers: .command)
        add(windowMenu, title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)))
        windowMenu.addItem(.separator())
        add(windowMenu, title: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = windowMenu
        // AppKit appends the live window list and the tab-management items
        // (Show Tab Bar / Merge All Windows / …) to this menu automatically.
        
        // MARK: Help menu
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        
        //        add(helpMenu, title: "ArtQuickLook Help",
        //            action: #selector(NSApplication.showHelp(_:)))
        NSApp.helpMenu = helpMenu
        
        return mainMenu
    }
    
    @discardableResult
    private static func add(_ menu: NSMenu, title: String, action: Selector?,
                            key: String = "",
                            modifiers: NSEvent.ModifierFlags = [],
                            target: AnyObject? = nil) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target                       // nil = responder chain
        /// Generates a menu with recently opened documents from the given controller.
        func recentDocumentsMenu(for controller: AppController) -> NSMenu? {
            let menu = NSMenu(title: "Recent Documents")

            guard !controller.recentlyOpenedDocuments.isEmpty else { return nil }

            for url in controller.recentlyOpenedDocuments {
                let item = NSMenuItem()
                item.title = url.lastPathComponent
//                item.action = #selector(AppController.openDocument(_:))
                item.representedObject = url // Pass URL to the action handler
                menu.addItem(item)
            }
            return menu
        }
        
        return item
    }
}

// MARK: - App controller (target of the app-specific menu items)

final class AppController: NSObject {
    
    static let shared = AppController()

    private static let maxRecentItems = 10
    private(set) var recentlyOpenedDocuments: [URL] = []

    /// Adds a URL to the recent documents list.
    func addRecentDocument(_ url: URL) {
        // Remove existing entry if present
        recentlyOpenedDocuments.removeAll { $0 == url }
        
        // Insert at the front
        recentlyOpenedDocuments.insert(url, at: 0)

        // Trim the list if it exceeds max count
        if recentlyOpenedDocuments.count > Self.maxRecentItems {
            recentlyOpenedDocuments.removeLast(recentlyOpenedDocuments.count - Self.maxRecentItems)
        }
    }

    /// Gets the list of recently opened documents.
    func getRecentDocuments() -> [URL] {
        return recentlyOpenedDocuments
    }

    // MARK: Settings window — AppKit-owned singleton
    
    /// Created on first use, kept alive, reused afterwards. Plain AppKit
    /// ownership: no Settings scene (no name collision, no private
    /// selectors, and it never tabs thanks to tabbingMode = .disallowed).
    private var settingsWindow: NSWindow?
    
    @objc func showSettingsWindow(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                                  styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "ArtQuickLook Settings"
            window.tabbingMode = .disallowed          // never joins document tab groups
            window.isReleasedWhenClosed = false       // reuse on next open
            window.setFrameAutosaveName("ArtQuickLookSettings")
            window.contentView = NSHostingView(rootView: ContentView())
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    
    // MARK: Open…
    
    /// `NSOpenPanel` rather than SwiftUI's `.fileImporter`; documents land in
    /// a DocumentWindowCoordinator window, same as Finder/dock opens.
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a Mischief .art document"
        panel.allowedContentTypes = [UTType(filenameExtension: "art") ?? .data]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.addRecentDocument(url)
            DocumentWindowCoordinator.shared.open(url: url)
        }
    }
    
    // MARK: View-menu resets
    
    @objc func resetView(_ sender: NSMenuItem?)     { LiveMTKView.resetFocused(.all) }
    @objc func resetPan(_ sender: NSMenuItem?)      { LiveMTKView.resetFocused(.pan) }
    @objc func resetZoom(_ sender: NSMenuItem?)     { LiveMTKView.resetFocused(.zoom) }
    @objc func resetRotation(_ sender: NSMenuItem?) { LiveMTKView.resetFocused(.rotation) }
}

extension AppController: NSMenuItemValidation {
    
    /// AppKit menu validation (items auto-enable only if the target allows).
    /// Same state source as the SwiftUI era: DocumentFocusModel, driven by
    /// NSWindow key notifications — but read directly, no Observable dance.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
            case #selector(resetView(_:)),
                #selector(resetPan(_:)),
                #selector(resetZoom(_:)),
                #selector(resetRotation(_:)):
                return DocumentFocusModel.shared.hasFocusedDocument
            default:
                return true
        }
    }
}
