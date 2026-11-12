// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import QuartzCore

/// A CSS-like drop shadow: vertical offset, blur and opacity.
struct ShadowSpec: Equatable {
    var offsetY: CGFloat
    var blur: CGFloat
    var opacity: CGFloat
}

/// Draws the sticker's shadow. The panel's own shadow is off, because it cannot
/// be animated between the "resting" and "lifted" looks (spec 6.2).
///
/// Layer-hosting on purpose: AppKit leaves the layers of a hosting view alone,
/// so their shadow properties can be animated freely.
final class ShadowHostView: NSView {
    private let shadowLayer = CALayer()

    var cornerRadius: CGFloat = 3 {
        didSet { updatePath() }
    }

    /// Paper rect in this view's coordinates.
    var paperRect: CGRect = .zero {
        didSet {
            if paperRect != oldValue { updatePath() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let host = CALayer()
        layer = host
        wantsLayer = true
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0
        shadowLayer.masksToBounds = false
        host.addSublayer(shadowLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds
        CATransaction.commit()
        updatePath()
    }

    func apply(_ spec: ShadowSpec, duration: CFTimeInterval, curve: MotionCurve) {
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(curve.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        shadowLayer.shadowOpacity = Float(spec.opacity)
        // CSS blur is roughly twice the Core Animation shadow radius.
        shadowLayer.shadowRadius = spec.blur / 2
        // The hosting layer keeps the default macOS geometry (y grows upwards), so "down" is negative.
        shadowLayer.shadowOffset = CGSize(width: 0, height: -spec.offsetY)
        CATransaction.commit()
    }

    private func updatePath() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.shadowPath = CGPath(
            roundedRect: paperRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        CATransaction.commit()
    }
}

/// The coloured paper with its glue strip. Layer-hosting for the same reason as `ShadowHostView`.
final class PaperFillView: NSView {
    private let fillLayer = CALayer()
    private let stripLayer = CALayer()
    private let glossLayer = CAGradientLayer()

    var stripHeight: CGFloat = 14 {
        didSet { layoutLayers() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let host = CALayer()
        layer = host
        wantsLayer = true

        fillLayer.masksToBounds = true
        fillLayer.borderWidth = 0.5
        host.addSublayer(fillLayer)
        fillLayer.addSublayer(stripLayer)

        // A barely visible gloss along the top of the glue strip (spec 6.2).
        glossLayer.colors = [
            NSColor.white.withAlphaComponent(0.10).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        // Default macOS layer geometry: y = 1 is the top edge.
        glossLayer.startPoint = CGPoint(x: 0.5, y: 1)
        glossLayer.endPoint = CGPoint(x: 0.5, y: 0)
        stripLayer.addSublayer(glossLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    func setColors(paper: NSColor, strip: NSColor, border: NSColor, cornerRadius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.backgroundColor = paper.cgColor
        fillLayer.borderColor = border.cgColor
        fillLayer.cornerRadius = cornerRadius
        stripLayer.backgroundColor = strip.cgColor
        CATransaction.commit()
    }

    func setPaperOpacity(_ opacity: CGFloat, duration: CFTimeInterval, curve: MotionCurve) {
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(curve.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        fillLayer.opacity = Float(opacity)
        CATransaction.commit()
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = bounds
        // Default macOS layer geometry: the top of the paper is at the largest y.
        stripLayer.frame = CGRect(x: 0, y: bounds.height - stripHeight, width: bounds.width, height: stripHeight)
        glossLayer.frame = stripLayer.bounds
        CATransaction.commit()
    }
}

/// Fades the bottom of an over-long sticker into the paper colour (spec 4.6).
final class OverflowFadeView: NSView {
    var paperColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let gradient = NSGradient(
            starting: paperColor.withAlphaComponent(0),
            ending: paperColor
        ) else { return }
        // Flipped view: minY is the top, so the fade goes from transparent (top) to paper (bottom).
        gradient.draw(
            from: NSPoint(x: bounds.midX, y: bounds.minY),
            to: NSPoint(x: bounds.midX, y: bounds.maxY),
            options: []
        )
    }
}
