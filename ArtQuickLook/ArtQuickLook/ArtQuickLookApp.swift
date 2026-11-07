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
        // Ensure the focus model (and its window observers) exist from launch.
        _ = DocumentFocusModel.shared
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
        
        // Open Recent: standard items + Clear Menu, rebuilt on demand from the
        // coordinator-fed recents list (OpenRecentMenuDelegate).
        let recentsItem = add(fileMenu, title: "Open Recent", action: nil, target: nil)
        let recentsMenu = NSMenu(title: "Open Recent")
        recentsMenu.delegate = OpenRecentMenuDelegate.shared
        recentsItem.submenu = recentsMenu
        
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
        viewMenu.addItem(.separator())
        add(viewMenu, title: "Flip Horizontal",
            action: #selector(AppController.flipHorizontal(_:)),
            key: "h", modifiers: [.command, .option], target: AppController.shared)
        add(viewMenu, title: "Flip Vertical",
            action: #selector(AppController.flipVertical(_:)),
            key: "v", modifiers: [.command, .option], target: AppController.shared)
        viewMenu.addItem(.separator())
        add(viewMenu, title: "Layer Stack",
            action: #selector(AppController.showLayerStack(_:)),
            key: "l", modifiers: [.command, .option], target: AppController.shared)
        viewMenu.addItem(.separator())
        
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
        return item
    }
}

// MARK: - Open Recent submenu

/// Rebuilds the Open Recent submenu whenever it is about to open, from
/// AppController's recents list. Items target AppController, so the standard
/// validation path applies; the URL rides in `representedObject`.
final class OpenRecentMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = OpenRecentMenuDelegate()
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        
        for url in AppController.shared.recentlyOpenedDocuments {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(AppController.openRecentDocument(_:)),
                                  keyEquivalent: "")
            item.target = AppController.shared
            item.representedObject = url
            menu.addItem(item)
        }
        
        menu.addItem(.separator())
        // Standard tail: always present, greyed out while the list is empty
        // (validation in AppController).
        let clear = NSMenuItem(title: "Clear Menu",
                               action: #selector(AppController.clearRecentDocuments(_:)),
                               keyEquivalent: "")
        clear.target = AppController.shared
        menu.addItem(clear)
    }
}

// MARK: - App controller (target of the app-specific menu items)

final class AppController: NSObject {
    
    static let shared = AppController()

    private static let maxRecentItems = 10
    private static let recentsKey = "recentlyOpenedArtDocuments"

    private struct RecentEntry {
        let url: URL
        /// Security-scoped bookmark. The app is sandboxed: a relaunched
        /// process has no access to a file that is merely known by path, so
        /// recents are persisted as bookmarks (created while this process
        /// still had access) instead of paths.
        let bookmark: Data
    }
    private var recents: [RecentEntry] = []

    /// Bookmark-resolved URLs, for menu building and validation.
    var recentlyOpenedDocuments: [URL] {
        recents.map(\.url)
    }

    /// Security scopes opened and kept for the whole session (one per URL once
    /// accessed — access starts when a recent item is opened).
    private var activeScopes: Set<URL> = []

    /// Overrides NSObject's `init()`; only `shared` constructs the controller.
    override private init() {
        let stored = UserDefaults.standard.array(forKey: Self.recentsKey) as? [Data] ?? []
        // Bookmark resolution itself needs no sandbox access; recovering the
        // URL is enough. Entries whose bookmark is obsolete are dropped.
        recents = stored.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: .withoutUI,
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale)
            else { return nil }
            return RecentEntry(url: url, bookmark: data)
        }
    }

    /// Adds a URL to the recent documents list.
    func addRecentDocument(_ url: URL) {
        // Bookmark right now: this process has access to the file at this
        // moment (dock drop, open panel, Open Recent scope). Saving at a
        // later relaunch could not re-create bookmarks for older entries.
        let entry = RecentEntry(url: url,
                                bookmark: (try? url.bookmarkData()) ?? Data())

        // Remove existing entry if present
        recents.removeAll { $0.url == url }

        // Insert at the front
        recents.insert(entry, at: 0)

        // Trim the list if it exceeds max count
        if recents.count > Self.maxRecentItems {
            recents.removeLast(recents.count - Self.maxRecentItems)
        }
        saveRecents()
    }

    /// Open Recent's "Clear Menu".
    @objc func clearRecentDocuments(_ sender: Any?) {
        recents.removeAll()
        saveRecents()
    }

    /// An item in the Open Recent submenu; opens like any other document.
    @objc func openRecentDocument(_ sender: NSMenuItem?) {
        guard let url = sender?.representedObject as? URL else { return }
        openSecurityScope(for: url)
        DocumentWindowCoordinator.shared.open(url: url)
    }

    /// Opens (and keeps until the process ends) the security scope for a URL.
    /// Without it, the first read after a relaunch would be denied by the
    /// sandbox — Finder/open-panel opens are granted implicitly, recents are
    /// not.
    private func openSecurityScope(for url: URL) {
        let key = url.standardizedFileURL
        guard !activeScopes.contains(key) else { return }
        if url.startAccessingSecurityScopedResource() {
            activeScopes.insert(key)
        }
    }

    private func saveRecents() {
        UserDefaults.standard.set(recents.map(\.bookmark), forKey: Self.recentsKey)
    }

    /// .getRecentDocuments — kept for compatibility with earlier callers.
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
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose a Mischief .art document"
        panel.allowedContentTypes = [UTType(filenameExtension: "art") ?? .data]
        panel.begin { response in
            guard response == .OK else { return }
            // Recents are recorded centrally by DocumentWindowCoordinator.open
            // (same as Finder/dock opens).
            for url in panel.urls {
                DocumentWindowCoordinator.shared.open(url: url)
            }
        }
    }
    
    // MARK: View-menu resets
    
    @objc func resetView(_ sender: NSMenuItem?)     { LiveMTKView.resetFocused(.all) }
    @objc func resetPan(_ sender: NSMenuItem?)      { LiveMTKView.resetFocused(.pan) }
    @objc func resetZoom(_ sender: NSMenuItem?)     { LiveMTKView.resetFocused(.zoom) }
    @objc func resetRotation(_ sender: NSMenuItem?) { LiveMTKView.resetFocused(.rotation) }

    @objc func flipHorizontal(_ sender: NSMenuItem?) { LiveMTKView.flipFocusedHorizontal() }
    @objc func flipVertical(_ sender: NSMenuItem?) { LiveMTKView.flipFocusedVertical() }

    @objc func showLayerStack(_ sender: Any?) { LayerStackPanelController.shared.toggle() }
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
                #selector(resetRotation(_:)),
                #selector(flipHorizontal(_:)),
                #selector(flipVertical(_:)):
                if menuItem.action == #selector(flipHorizontal(_:)) {
                    menuItem.state = LiveMTKView.focusedFlipHorizontal ? .on : .off
                } else if menuItem.action == #selector(flipVertical(_:)) {
                    menuItem.state = LiveMTKView.focusedFlipVertical ? .on : .off
                }
                return LiveMTKView.hasFocusedDocument
            case #selector(openRecentDocument(_:)):
                return true
            case #selector(clearRecentDocuments(_:)):
                return !recentlyOpenedDocuments.isEmpty
            default:
                return true
        }
    }
}
