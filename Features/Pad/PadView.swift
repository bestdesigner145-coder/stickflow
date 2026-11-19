// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

/// The pad of blank stickers that comes out of the screen edge (spec 4.2):
/// a few sheets, the top one with a curled corner and a handwritten label.
final class PadView: NSView {
    /// Called on a click: tear off a sheet.
    var onClick: (() -> Void)?

    var paper: PaperColor = .default {
        didSet { needsDisplay = true }
    }

    /// The corner the fold is drawn in points away from the screen edge.
    var edge: ScreenSide = .right {
        didSet { needsDisplay = true }
    }

    /// How much of the pad stays behind the screen edge when it is out. The label
    /// is centred on what can be seen.
    var hiddenWidth: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    /// The handwritten words on the top sheet.
    var label: String = L10n.padLabel {
        didSet { needsDisplay = true }
    }

    /// Size of the label; it shrinks until the longest word fits the sheet.
    var labelFontSize: CGFloat = 20 {
        didSet { needsDisplay = true }
    }

    var minimumLabelFontSize: CGFloat = 13 {
        didSet { needsDisplay = true }
    }

    private(set) var isHovered = false {
        didSet { needsDisplay = true }
    }

    private var trackingArea: NSTrackingArea?

    /// Sheets under the top one, each shifted by a point.
    private static let sheetCount = 6
    private static let foldSize: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L10n.padLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    #if DEBUG
    /// For snapshots: draws the pad as if the cursor was over it.
    func setHoveredForSnapshot(_ hovered: Bool) {
        isHovered = hovered
    }
    #endif

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        let paperColor = paper.paperColor(dark: dark)
        let stack = CGFloat(Self.sheetCount)
        // The top sheet; the others peek out below it, away from the fold.
        let side = min(bounds.width, bounds.height) - stack - 4
        let lift: CGFloat = isHovered ? 2 : 0
        let top = NSRect(x: bounds.minX + 2, y: bounds.maxY - side - 2 + lift, width: side, height: side)

        for index in stride(from: Self.sheetCount, to: 0, by: -1) {
            let offset = CGFloat(index)
            let sheet = top.offsetBy(dx: offset, dy: -offset - lift)
            let shade = 0.03 + 0.012 * offset
            paperColor.blended(withFraction: shade, of: .black)?.setFill()
            let path = NSBezierPath(roundedRect: sheet, xRadius: 2, yRadius: 2)
            path.fill()
            NSColor.black.withAlphaComponent(0.10).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }

        // The top sheet with its bottom corner folded up.
        let fold = Self.foldSize + (isHovered ? 5 : 0)
        let foldsOnLeft = edge == .right
        let cornerX = foldsOnLeft ? top.minX : top.maxX
        let inward: CGFloat = foldsOnLeft ? 1 : -1
        let sheetPath = NSBezierPath()
        sheetPath.move(to: NSPoint(x: top.minX, y: top.maxY))
        sheetPath.line(to: NSPoint(x: top.maxX, y: top.maxY))
        if foldsOnLeft {
            sheetPath.line(to: NSPoint(x: top.maxX, y: top.minY))
            sheetPath.line(to: NSPoint(x: top.minX + fold, y: top.minY))
            sheetPath.line(to: NSPoint(x: top.minX, y: top.minY + fold))
        } else {
            sheetPath.line(to: NSPoint(x: top.maxX, y: top.minY + fold))
            sheetPath.line(to: NSPoint(x: top.maxX - fold, y: top.minY))
            sheetPath.line(to: NSPoint(x: top.minX, y: top.minY))
        }
        sheetPath.close()
        paperColor.setFill()
        sheetPath.fill()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        sheetPath.lineWidth = 0.5
        sheetPath.stroke()

        // The folded corner shows the back of the sheet, a little darker.
        let foldPath = NSBezierPath()
        foldPath.move(to: NSPoint(x: cornerX + inward * fold, y: top.minY))
        foldPath.line(to: NSPoint(x: cornerX, y: top.minY + fold))
        foldPath.line(to: NSPoint(x: cornerX + inward * fold, y: top.minY + fold))
        foldPath.close()
        paperColor.blended(withFraction: dark ? 0.18 : 0.10, of: dark ? .white : .black)?.setFill()
        foldPath.fill()
        NSColor.black.withAlphaComponent(0.14).setStroke()
        foldPath.lineWidth = 0.5
        foldPath.stroke()

        var labelArea = top.insetBy(dx: 10, dy: 12)
        labelArea.size.width -= hiddenWidth
        if edge == .left { labelArea.origin.x += hiddenWidth }
        drawLabel(in: labelArea)
    }

    private func drawLabel(in rect: NSRect) {
        // A line may break between words only, so the longest word sets the size.
        let baseFont = HandFont.font(size: labelFontSize)
        let widestWord = LabelFit.words(of: label)
            .map { ceil(NSAttributedString(string: $0, attributes: [.font: baseFont]).size().width) }
            .max() ?? 0
        let size = LabelFit.fontSize(
            base: Double(labelFontSize),
            minimum: Double(minimumLabelFontSize),
            widestWord: Double(widestWord),
            available: Double(rect.width) - 2
        )
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        style.maximumLineHeight = CGFloat(size) + 1
        let text = NSAttributedString(string: label, attributes: [
            .font: HandFont.font(size: CGFloat(size)),
            .foregroundColor: paper.textColor(alpha: 0.72),
            .paragraphStyle: style,
        ])
        let needed = text.boundingRect(with: NSSize(width: rect.width, height: 200), options: [.usesLineFragmentOrigin])
        let height = ceil(needed.height)
        let target = NSRect(x: rect.minX, y: rect.midY - height / 2 + 2, width: rect.width, height: height)
        text.draw(with: target, options: [.usesLineFragmentOrigin])
    }
}

/// The soft oval behind the pad (reference 02). It thins out to nothing well
/// before its border, so that no edge can be seen (fix H5).
final class PadGlowView: NSView {
    /// Opacity in the middle.
    var strength: CGFloat = 0.1 {
        didSet {
            if strength != oldValue { needsDisplay = true }
        }
    }

    private static let steps = 8

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, bounds.width > 0, bounds.height > 0 else { return }
        let white: CGFloat = effectiveAppearance.isDark ? 1 : 0
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        for step in 0...Self.steps {
            let distance = CGFloat(step) / CGFloat(Self.steps)
            // Falls off quickly at first and leaves a long quiet tail.
            colors.append(CGColor(gray: white, alpha: strength * (1 - distance) * (1 - distance)))
            locations.append(distance)
        }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors as CFArray, locations: locations) else {
            return
        }
        context.saveGState()
        // A circle of radius one, stretched into the oval.
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.scaleBy(x: bounds.width / 2, y: bounds.height / 2)
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        context.restoreGState()
    }
}

/// The pad's shadow: wide, blurred and faint (fix H5). Layer-hosting, so that
/// AppKit leaves the layer's shadow alone; the path spares the render server
/// from working the shape out of the pixels.
final class PadShadowView: NSView {
    private let host = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = host
        wantsLayer = true
        host.shadowColor = NSColor.black.cgColor
        host.shadowOpacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(radius: CGFloat, offsetY: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.shadowRadius = radius
        host.shadowOffset = CGSize(width: 0, height: -offsetY)
        host.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), cornerWidth: 3, cornerHeight: 3, transform: nil)
        CATransaction.commit()
    }

    /// Opacity of the shadow right now, for tests.
    var opacity: Float { host.shadowOpacity }

    func setOpacity(_ opacity: Float, duration: TimeInterval, curve: MotionCurve) {
        let from = host.presentation()?.shadowOpacity ?? host.shadowOpacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.shadowOpacity = opacity
        CATransaction.commit()
        guard duration > 0 else {
            host.removeAnimation(forKey: "shadow")
            return
        }
        let animation = CABasicAnimation(keyPath: "shadowOpacity")
        animation.fromValue = from
        animation.duration = duration
        animation.timingFunction = curve.timingFunction
        host.add(animation, forKey: "shadow")
    }
}

/// The thin strip of paper at the edge that hints where the pad is (spec 4.1).
final class EdgeTabView: NSView {
    var paper: PaperColor = .default {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        paper.paperColor(dark: effectiveAppearance.isDark).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
    }
}
