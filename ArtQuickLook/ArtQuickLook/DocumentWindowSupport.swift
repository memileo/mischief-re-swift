//
//  DocumentWindowSupport.swift
//  Shared plumbing for the coordinator-managed document windows:
//  window configuration (proxy icon + tabbing) and menu-validation state.
//
//  The settings window is SwiftUI's own `Settings` scene (singleton, macOS
//  11+); it shares none of this and never joins a document tab group.
//

import AppKit
import SwiftUI

enum DocumentWindowSupport {
    /// Shared by all document windows so they merge into one tab group.
    static let tabbingIdentifier = "org.potato.ArtQuickLook.document"
}

// MARK: - Window configuration

extension NSWindow {
    /// Call once from `DocumentWindowCoordinator` right after creating each
    /// document `NSWindow` (keep setting `title = url.lastPathComponent` as before).
    ///
    /// * `representedURL` puts the file's icon in the title bar — the standard
    ///   proxy icon. Draggable straight into Finder (drag = move, ⌥-drag = copy),
    ///   and ⌘-click on the window title pops up the path menu. Both are stock
    ///   NSWindow behaviour; no extra code is needed.
    /// * `isDocumentEdited = false` keeps the "edited" dot out of the close
    ///   button (this is a viewer).
    /// * Tabbing: `.preferred` plus the shared identifier makes document windows
    ///   open as tabs of each other (with `NSWindow.allowsAutomaticWindowTabbing`
    ///   enabled at launch — see the app delegate). The Settings window never
    ///   participates: it is a SwiftUI-managed singleton with no shared
    ///   identifier, and SettingsWindowTagger (ArtQuickLookApp.swift) tags
    ///   it `.disallowed` the moment the window exists.
    /// * The tabbing identifier doubles as the discriminator
    ///   `DocumentFocusModel` uses to recognise document windows.
    func configureAsArtDocument(url: URL) {
        representedURL = url
        isDocumentEdited = false
        tabbingMode = .preferred
        tabbingIdentifier = DocumentWindowSupport.tabbingIdentifier
    }
}

// MARK: - Menu validation state

/// Single source of truth for "the key window is a document window".
///
/// `LiveMTKView.hasFocusedDocument` is a plain static, so SwiftUI never sees it
/// change — that is why the View-menu resets were permanently greyed out. This
/// model is driven by NSWindow key notifications instead and is observed by the
/// App struct (`@StateObject`), so the commands re-render on macOS 12 and 13
/// alike. Actions still route through `LiveMTKView.resetFocused(_:)`, which
/// keeps working exactly as before.
final class DocumentFocusModel: ObservableObject {
    static let shared = DocumentFocusModel()
    
    @Published private(set) var hasFocusedDocument = false
    
    private init() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowStatusChanged),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowStatusChanged),
                           name: NSWindow.didResignKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowStatusChanged),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
        // Seed initial state (the first document window may already be key).
        windowStatusChanged()
    }
    
    @objc private func windowStatusChanged() {
        // Recompute from scratch: whatever the notification was, the current key
        // window is the truth. Covers switching windows, closing the key window
        // (didResignKey fires before the window goes away) and app reactivation.
        let focused = NSApp.keyWindow.map(Self.isDocumentWindow) ?? false
        if focused != hasFocusedDocument {
            hasFocusedDocument = focused
        }
    }
    
    /// Internal rather than private so window helpers elsewhere in the target
    /// can reuse the same document-window test (e.g. for focus bookkeeping).
    static func isDocumentWindow(_ window: NSWindow) -> Bool {
        // configureAsArtDocument(url:) sets both of these; the representedURL
        // check keeps the model correct even if only the proxy icon was wired up.
        window.tabbingIdentifier == DocumentWindowSupport.tabbingIdentifier
        || window.representedURL != nil
    }
}
