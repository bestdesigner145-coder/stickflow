// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// "New / Add to sticker" in the draft's corner (spec 4.3). Shown only while
/// there is a sticker to add to.
final class ModeToggleView: NSView {
    /// False: a new sticker. True: the lines go into the top sticker.
    var isAppend = false {
        didSet {
            guard isAppend != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(isAppend ? titles[1] : titles[0])
            onChange?()
        }
    }

    var onChange: (() -> Void)?

    var tint = NSColor.labelColor {
        didSet { needsDisplay = true }
    }

    private let titles = [L10n.draftModeNew, L10n.draftModeAppend]
    private static let gap: CGFloat = 10
    private var splitX: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityValue(titles[0])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func text(_ index: Int) -> NSAttributedString {
        let isActive = (index == 1) == isAppend
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: isActive ? .semibold : .regular),
            .foregroundColor: tint.withAlphaComponent(isActive ? 0.85 : 0.42),
        ]
        if isActive {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: titles[index], attributes: attributes)
    }

    /// Wide enough for both words in their bold form.
    var fittingSize: NSSize {
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]
        let widths = titles.map { ceil(NSAttributedString(string: $0, attributes: bold).size().width) }
        return NSSize(width: widths[0] + Self.gap + widths[1], height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]
        let firstWidth = ceil(NSAttributedString(string: titles[0], attributes: bold).size().width)
        text(0).draw(at: NSPoint(x: 0, y: 1))
        text(1).draw(at: NSPoint(x: firstWidth + Self.gap, y: 1))
        splitX = firstWidth + Self.gap / 2
    }

    override func mouseDown(with event: NSEvent) {
        isAppend = convert(event.locationInWindow, from: nil).x > splitX
    }

    override func accessibilityPerformPress() -> Bool {
        isAppend.toggle()
        return true
    }
}

/// A word to click, written on the paper: "Stick", "Try again".
final class PaperTextButton: NSView {
    var onClick: (() -> Void)?

    var tint = NSColor.labelColor {
        didSet { needsDisplay = true }
    }

    private let title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var text: NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: tint,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
    }

    var fittingSize: NSSize {
        let size = text.size()
        return NSSize(width: ceil(size.width), height: ceil(size.height) + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        text.draw(at: NSPoint(x: 0, y: 1))
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// The drawn spinner of "Sorting…" (spec 6.7: one turn in 0.8 s, linear; it
/// stands still with Reduce Motion).
final class SpinnerView: NSView {
    private let arc = CAShapeLayer()

    var tint = NSColor.labelColor {
        didSet { arc.strokeColor = tint.cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let host = CALayer()
        layer = host
        wantsLayer = true
        arc.fillColor = nil
        arc.lineWidth = 1.5
        arc.lineCap = .round
        arc.strokeColor = tint.cgColor
        host.addSublayer(arc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        let radius = max(min(bounds.width, bounds.height) / 2 - 1.5, 1)
        let path = CGMutablePath()
        // Three quarters of a circle, like a pen stroke that has not closed.
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius, startAngle: 0, endAngle: 1.5 * .pi, clockwise: false)
        arc.path = path
        CATransaction.commit()
    }

    /// - Parameter period: seconds per turn; 0 leaves the spinner standing.
    func setSpinning(_ isSpinning: Bool, period: TimeInterval) {
        let key = "spin"
        guard isSpinning, period > 0 else {
            arc.removeAnimation(forKey: key)
            return
        }
        guard arc.animation(forKey: key) == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = period
        turn.repeatCount = .infinity
        turn.timingFunction = CAMediaTimingFunction(name: .linear)
        arc.add(turn, forKey: key)
    }
}
