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

/// Covers the bottom of an over-long sticker (spec 4.6): the last visible lines
/// fade into the paper colour, and below them the paper is solid so the
/// "4 more" label has a clean background.
final class OverflowFadeView: NSView {
    var paperColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    /// Height of the gradient at the top of the view; the rest is filled solid.
    var gradientHeight: CGFloat = 28 {
        didSet {
            if gradientHeight != oldValue { needsDisplay = true }
        }
    }

    /// Radius of the two bottom corners, to follow the paper's shape.
    var cornerRadius: CGFloat = 0 {
        didSet {
            if cornerRadius != oldValue { needsDisplay = true }
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Flipped view: y = 0 is the top.
        let split = min(max(gradientHeight, 0), bounds.height)
        // Extending the shape upwards keeps the top corners square and rounds only the bottom ones.
        let shape = NSRect(x: 0, y: -cornerRadius, width: bounds.width, height: bounds.height + cornerRadius)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // `NSGradient.draw(from:to:)` paints the whole clip region, and views do not
        // clip to their bounds by default, so the clip has to be set explicitly.
        NSBezierPath(rect: bounds).addClip()
        NSBezierPath(roundedRect: shape, xRadius: cornerRadius, yRadius: cornerRadius).addClip()

        paperColor.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: split, width: bounds.width, height: bounds.height - split)).fill()

        guard split > 0,
              let gradient = NSGradient(starting: paperColor.withAlphaComponent(0), ending: paperColor)
        else { return }
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: split)).addClip()
        gradient.draw(
            from: NSPoint(x: bounds.midX, y: 0),
            to: NSPoint(x: bounds.midX, y: split),
            options: []
        )
    }
}
