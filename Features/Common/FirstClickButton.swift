// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// A button that reacts to the first click even though its window is never key.
/// Stickflow's panels do not take keyboard focus, so a plain `NSButton` would
/// need one click to "wake" the window and another to act.
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A borderless button showing an SF Symbol, for the sticker's glue strip.
    static func symbol(_ name: String, pointSize: CGFloat, description: String) -> FirstClickButton {
        let button = FirstClickButton(frame: .zero)
        button.isBordered = false
        button.title = ""
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        button.setAccessibilityLabel(description)
        return button
    }
}
