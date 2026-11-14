// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// The short message at the bottom of the screen after a sticker is peeled off:
/// "Sticker peeled off · Restore" (spec 4.10). System-style UI, not paper (spec 6.1).
@MainActor
final class ToastController: NSObject {
    private var panel: NSPanel?
    private let background = ToastBackgroundView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private let button = FirstClickButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?
    private var outDuration: TimeInterval = 0.15

    /// Called when a toast that was on offer goes away for any reason:
    /// its time ran out, its button was clicked, or it was hidden.
    var onDismiss: (() -> Void)?

    #if DEBUG
    /// For the self-check's snapshots.
    var snapshotView: NSView? { panel?.contentView }
    #endif

    /// True while a toast is on screen.
    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the toast, replacing any previous one.
    /// - Parameter action: runs when the button is clicked; the toast then closes.
    func show(
        message: String,
        actionTitle: String,
        on screen: NSScreen,
        tuning: Tuning,
        action: @escaping () -> Void
    ) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        self.action = action
        outDuration = tuning.scaled(tuning.toastOutDuration)

        label.stringValue = message
        button.attributedTitle = NSAttributedString(
            string: actionTitle,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: SystemPalette.accent,
            ]
        )
        label.sizeToFit()
        button.sizeToFit()

        let padding: CGFloat = 14
        let gap: CGFloat = 12
        let height: CGFloat = 36
        let labelSize = label.frame.size
        let buttonSize = button.frame.size
        let width = padding + ceil(labelSize.width) + gap + ceil(buttonSize.width) + padding
        label.frame = NSRect(
            x: padding,
            y: ((height - labelSize.height) / 2).rounded(),
            width: ceil(labelSize.width),
            height: labelSize.height
        )
        button.frame = NSRect(
            x: padding + ceil(labelSize.width) + gap,
            y: ((height - buttonSize.height) / 2).rounded(),
            width: ceil(buttonSize.width),
            height: buttonSize.height
        )

        let visible = screen.visibleFrame
        let target = NSRect(
            x: (visible.midX - width / 2).rounded(),
            y: visible.minY + 24,
            width: width,
            height: height
        )

        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(timeoutFired), object: nil)
        perform(#selector(timeoutFired), with: nil, afterDelay: tuning.toastDuration)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shift = reduceMotion ? 0 : CGFloat(tuning.toastShift)
        panel.alphaValue = 0
        panel.setFrame(target.offsetBy(dx: 0, dy: -shift), display: true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = tuning.scaled(tuning.toastInDuration)
            context.timingFunction = MotionCurve.easeOut.timingFunction
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide(animated: Bool = true) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(timeoutFired), object: nil)
        if action != nil {
            action = nil
            onDismiss?()
        }
        guard let panel, panel.isVisible else { return }
        guard animated, outDuration > 0 else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = outDuration
            context.timingFunction = MotionCurve.easeOut.timingFunction
            panel.animator().alphaValue = 0
        }, completionHandler: { [self] in
            MainActor.assumeIsolated {
                self.finishHiding()
            }
        })
    }

    private func finishHiding() {
        // A new toast may have appeared while the old one was fading out.
        guard action == nil else { return }
        panel?.orderOut(nil)
    }

    /// Runs the toast's action as if its button was clicked.
    func performAction() {
        let pending = action
        hide()
        pending?()
    }

    @objc private func buttonClicked() {
        performAction()
    }

    @objc private func timeoutFired() {
        hide()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 36),
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
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        background.frame = NSRect(x: 0, y: 0, width: 240, height: 36)
        background.autoresizingMask = [.width, .height]

        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = SystemPalette.text
        label.lineBreakMode = .byTruncatingTail

        button.isBordered = false
        button.target = self
        button.action = #selector(buttonClicked)

        background.addSubview(label)
        background.addSubview(button)
        panel.contentView = background
        return panel
    }
}

/// Colours of Stickflow's system-style UI (spec 6.3).
@MainActor
enum SystemPalette {
    static let background = dynamic(light: 0xFFFFFF, dark: 0x202020)
    static let text = dynamic(light: 0x37352F, dark: 0xE6E6E4)
    static let accent = dynamic(light: 0x2383E2, dark: 0x529CCA)
    static let divider = dynamic(light: 0x37352F, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.08)

    /// A colour that follows the appearance of the view it is drawn in.
    private static func dynamic(
        light: UInt32,
        lightAlpha: CGFloat = 1,
        dark: UInt32,
        darkAlpha: CGFloat = 1
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(rgb: dark, alpha: darkAlpha)
                : NSColor(rgb: light, alpha: lightAlpha)
        }
    }
}

/// Rounded background of the toast: panel colour, hairline border, radius 10.
private final class ToastBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        SystemPalette.background.setFill()
        shape.fill()
        SystemPalette.divider.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
