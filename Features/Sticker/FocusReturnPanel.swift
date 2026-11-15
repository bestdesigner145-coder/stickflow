// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// Hands keyboard focus back to the app the user was working in.
///
/// A non-activating panel that became key keeps the keyboard until some window
/// takes it or the panel leaves the screen. Hiding and re-showing the sticker
/// works, but the sticker blinks. This invisible panel takes key status from
/// the sticker instead and then leaves the screen itself: the system returns
/// the keyboard to the previous app, and the sticker is never touched.
final class FocusReturnPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func make() -> FocusReturnPanel {
        let panel = FocusReturnPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        return panel
    }

    /// Takes key status from whichever Stickflow window has it and gives it up.
    /// - Parameter frame: where the editing happened; the helper appears there so
    ///   it is on the same screen and Space.
    func releaseFocus(near frame: NSRect) {
        setFrame(NSRect(x: frame.midX, y: frame.midY, width: 1, height: 1), display: false)
        orderFrontRegardless()
        makeKey()
        orderOut(nil)
    }
}
