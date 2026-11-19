// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// Brings a window of the app to the desktop the user is on (fix K2).
///
/// Stickflow lives in the menu bar and has no Dock icon. Ordered front before
/// the app is active, a window stays on the desktop it was first shown on, and
/// macOS switches there. Every ordinary window of the app — settings, "Voice →
/// tasks", Tuning — comes up through here, over a full-screen app as well.
@MainActor
enum WindowPresenter {
    /// What every such window needs: it follows the user to the active desktop
    /// and may stand over a full-screen app.
    static let behavior: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

    static func present(_ window: NSWindow, centred: Bool = false) {
        window.collectionBehavior.formUnion(behavior)
        if centred || !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
