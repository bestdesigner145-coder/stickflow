// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// A word to click, written on the paper: "Stick", "Try again". Without the
/// underline it is a plain line of status and takes no clicks.
final class PaperTextButton: NSView {
    var onClick: (() -> Void)?

    var tint = NSColor.labelColor {
        didSet { needsDisplay = true }
    }

    private(set) var title: String
    private(set) var isLink = true

    func set(title: String, isLink: Bool) {
        guard title != self.title || isLink != self.isLink else { return }
        self.title = title
        self.isLink = isLink
        setAccessibilityLabel(title)
        setAccessibilityRole(isLink ? .button : .staticText)
        needsDisplay = true
    }

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
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isLink ? .medium : .regular),
            .foregroundColor: tint,
        ]
        if isLink { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: title, attributes: attributes)
    }

    var naturalSize: NSSize {
        let size = text.size()
        return NSSize(width: ceil(size.width), height: ceil(size.height) + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Cut with an ellipsis rather than run under what stands next to it.
        let rect = NSRect(x: 0, y: 1, width: bounds.width, height: bounds.height)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func mouseDown(with event: NSEvent) {
        if isLink { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isLink else { return false }
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
