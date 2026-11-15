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

/// The soft grey oval behind the pad (reference 02).
final class PadGlowView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        let center = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.16 : 0.14)
        guard let gradient = NSGradient(starting: center, ending: center.withAlphaComponent(0)) else { return }
        let oval = NSBezierPath(ovalIn: bounds)
        gradient.draw(in: oval, relativeCenterPosition: .zero)
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
