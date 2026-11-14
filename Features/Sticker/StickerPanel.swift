// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// Window of a single sticker (spec 5.1): borderless, floats above other apps,
/// never activates Stickflow and lets clicks pass through by default.
final class StickerPanel: NSPanel {
    /// True only while the sticker is being edited. Otherwise the panel refuses
    /// keyboard focus so it can never steal typing from the active app.
    var allowsKeyStatus = false

    static func make() -> StickerPanel {
        let panel = StickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // shadows are drawn by the content view
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        return panel
    }

    override var canBecomeKey: Bool { allowsKeyStatus }
    override var canBecomeMain: Bool { false }

    /// Applies the settings that decide where and to whom the sticker is visible.
    ///
    /// - Parameters:
    ///   - showOverFullscreen: "show over full-screen apps" setting.
    ///   - usesWindowLevel: debug switch. Off (default): the setting adds or removes
    ///     `.fullScreenAuxiliary`. On: the spec variant, where the behaviour is always
    ///     present and the setting only raises the window level.
    ///   - floatsAcrossSpaces: debug switch. Off (spec): `.stationary`. On: `.transient`.
    ///   - hideFromScreenCapture: asks the system to leave the window out of
    ///     screenshots. Apps that share the screen through ScreenCaptureKit still
    ///     see it, and system animations that work on window snapshots may drop the
    ///     window while they run. Off by default.
    func applySystemBehavior(
        showOverFullscreen: Bool,
        usesWindowLevel: Bool,
        floatsAcrossSpaces: Bool,
        hideFromScreenCapture: Bool
    ) {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        behavior.insert(floatsAcrossSpaces ? .transient : .stationary)
        if usesWindowLevel {
            behavior.insert(.fullScreenAuxiliary)
            level = showOverFullscreen ? .statusBar : .floating
        } else {
            if showOverFullscreen {
                behavior.insert(.fullScreenAuxiliary)
            }
            level = .floating
        }
        if collectionBehavior != behavior {
            collectionBehavior = behavior
        }
        let wantedSharing: NSWindow.SharingType = hideFromScreenCapture ? .none : .readOnly
        if sharingType != wantedSharing {
            sharingType = wantedSharing
        }
    }
}
