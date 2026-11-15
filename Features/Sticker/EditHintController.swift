// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// The small "⌥ — edit" bubble shown next to the cursor the first few times it
/// rests on a sticker (spec 4.6).
@MainActor
final class EditHintController: NSObject {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func show(text: String, near location: CGPoint, duration: TimeInterval, hideFromScreenCapture: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        label.stringValue = text
        label.sizeToFit()
        let padding = NSSize(width: 9, height: 5)
        let size = NSSize(
            width: ceil(label.frame.width) + padding.width * 2,
            height: ceil(label.frame.height) + padding.height * 2
        )
        label.setFrameOrigin(NSPoint(x: padding.width, y: padding.height))

        // Below and to the right of the cursor, where it does not cover the arrow.
        let frame = NSRect(x: location.x + 14, y: location.y - size.height - 16, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.sharingType = hideFromScreenCapture ? .none : .readOnly
        panel.orderFrontRegardless()

        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideAfterDelay), object: nil)
        perform(#selector(hideAfterDelay), with: nil, afterDelay: duration)
    }

    func hide() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideAfterDelay), object: nil)
        panel?.orderOut(nil)
    }

    @objc private func hideAfterDelay() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 26),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let background = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
        background.autoresizingMask = [.width, .height]
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        background.layer?.cornerRadius = 6

        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        background.addSubview(label)

        panel.contentView = background
        return panel
    }
}
