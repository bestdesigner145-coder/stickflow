// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

/// Part of the sticker under the cursor (spec 4.6).
enum StickerZone {
    /// The top strip: drag to move.
    case glueStrip
    /// The checkbox of the task on the given editor line.
    case checkbox(line: Int)
    /// Anywhere else on the paper; the point is in the text view's coordinates.
    case body(pointInTextView: NSPoint)
}

@MainActor
protocol StickerRootViewDelegate: AnyObject {
    func rootView(_ view: StickerRootView, mouseDownIn zone: StickerZone, event: NSEvent)
    func rootView(_ view: StickerRootView, mouseDraggedWith event: NSEvent)
    func rootView(_ view: StickerRootView, mouseUpWith event: NSEvent)
    func rootViewDidClickMenuButton(_ view: StickerRootView)
    func rootViewDidChangeAppearance(_ view: StickerRootView)
}

/// A button that reacts to the first click even though its window is never key.
private final class ChromeButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Content view of a sticker panel.
///
/// The view is larger than the paper by `metrics.margin` on every side; the
/// transparent margin is where the shadow is drawn. Coordinates are flipped
/// (origin top-left), which keeps the layout code readable.
final class StickerRootView: NSView {
    struct Metrics: Equatable {
        var margin: CGFloat = 40
        var stripHeight: CGFloat = 14
        var cornerRadius: CGFloat = 3
        var bottomPadding: CGFloat = 8
    }

    weak var delegate: StickerRootViewDelegate?

    var metrics = Metrics() {
        didSet {
            guard metrics != oldValue else { return }
            effectView.maskImage = Self.roundedMask(radius: metrics.cornerRadius)
            relayout()
        }
    }

    let textView: BlockTextView
    private let scrollView: NSScrollView
    private let shadowView = ShadowHostView(frame: .zero)
    private let effectView = NSVisualEffectView(frame: .zero)
    private let fillView = PaperFillView(frame: .zero)
    private let overflowFade = OverflowFadeView(frame: .zero)
    private let counterLabel = NSTextField(labelWithString: "")
    private let moreLabel = NSTextField(labelWithString: "")
    private let menuButton = ChromeButton(frame: .zero)
    private var trackingArea: NSTrackingArea?
    private var isOverflowing = false
    private var hasCounter = false

    /// Strip at the bottom of an over-long sticker that holds the "4 more" label.
    private static let overflowFooterHeight: CGFloat = 16
    /// Height over which the last visible lines fade into the paper.
    private static let overflowFadeHeight: CGFloat = 28

    /// While editing, the text view handles its own mouse events.
    var isEditing = false {
        didSet {
            if isEditing != oldValue { refreshOverflow() }
        }
    }

    /// Strip buttons and darker checkboxes: visible in edit mode and while editing.
    private(set) var showsChrome = false

    // MARK: Construction

    override init(frame frameRect: NSRect) {
        let parts = BlockTextView.makeScrollable()
        scrollView = parts.scrollView
        textView = parts.textView
        super.init(frame: frameRect)
        wantsLayer = true

        // Blurs what is behind the sticker so the text stays readable on any background (spec 4.7).
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = false
        effectView.maskImage = Self.roundedMask(radius: metrics.cornerRadius)

        counterLabel.isHidden = true
        counterLabel.lineBreakMode = .byClipping
        moreLabel.isHidden = true
        overflowFade.isHidden = true

        menuButton.isBordered = false
        menuButton.title = ""
        menuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Menu")
        menuButton.imagePosition = .imageOnly
        menuButton.imageScaling = .scaleProportionallyDown
        menuButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        menuButton.target = self
        menuButton.action = #selector(menuButtonClicked)
        menuButton.isHidden = true

        addSubview(shadowView)
        addSubview(effectView)
        addSubview(fillView)
        addSubview(scrollView)
        addSubview(overflowFade)
        addSubview(moreLabel)
        addSubview(counterLabel)
        addSubview(menuButton)

        // The counter sits on the title line, so it has to follow the text when it scrolls.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        setBaseFontSize(14)
        relayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Layout

    /// The paper, in this view's coordinates.
    var paperRect: NSRect {
        bounds.insetBy(dx: metrics.margin, dy: metrics.margin)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    func relayout() {
        let paper = paperRect
        guard paper.width > 0, paper.height > 0 else { return }

        shadowView.frame = bounds
        shadowView.cornerRadius = metrics.cornerRadius
        // The margin is the same on every side, so the rect is identical in flipped and unflipped coordinates.
        shadowView.paperRect = paper
        effectView.frame = paper
        fillView.stripHeight = metrics.stripHeight
        fillView.frame = paper

        // At rest an over-long sticker keeps a footer for the "4 more" label.
        let footerHeight = isOverflowing && !isEditing ? Self.overflowFooterHeight : 0
        let textTop = paper.minY + metrics.stripHeight
        let textHeight = max(paper.height - metrics.stripHeight - metrics.bottomPadding - footerHeight, 0)
        scrollView.frame = NSRect(x: paper.minX, y: textTop, width: paper.width, height: textHeight)

        // Autoresizing moves the text view by a delta; pin its width to the visible width explicitly.
        let contentWidth = scrollView.contentSize.width
        if abs(textView.frame.width - contentWidth) > 0.5 {
            textView.setFrameSize(NSSize(width: contentWidth, height: textView.frame.height))
        }

        menuButton.frame = NSRect(x: paper.maxX - 28, y: paper.minY, width: 24, height: metrics.stripHeight)

        // The fade starts over the last visible lines and stays solid down to the paper's edge.
        let fadeHeight = min(Self.overflowFadeHeight, textHeight / 2)
        let fadeTop = textTop + textHeight - fadeHeight
        overflowFade.gradientHeight = fadeHeight
        overflowFade.cornerRadius = max(metrics.cornerRadius - 0.5, 0)
        overflowFade.frame = NSRect(
            x: paper.minX + 0.5,
            y: fadeTop,
            width: paper.width - 1,
            height: max(paper.maxY - 0.5 - fadeTop, 0)
        )
        layoutLabels()
    }

    private func layoutLabels() {
        let paper = paperRect
        let inset = BlockTextView.contentInset

        // While editing a long sticker the text scrolls; the counter moves with the title
        // and hides once the title is out of sight.
        let scrollOffset = isEditing ? max(scrollView.contentView.bounds.origin.y, 0) : 0
        counterLabel.sizeToFit()
        let counterSize = counterLabel.frame.size
        counterLabel.frame = NSRect(
            x: paper.maxX - inset.width - counterSize.width,
            y: paper.minY + metrics.stripHeight + inset.height + 2 - scrollOffset,
            width: counterSize.width,
            height: counterSize.height
        )
        counterLabel.isHidden = !hasCounter || scrollOffset > 4

        moreLabel.sizeToFit()
        let moreSize = moreLabel.frame.size
        moreLabel.frame = NSRect(
            x: paper.minX + inset.width,
            y: paper.maxY - moreSize.height - 6,
            width: moreSize.width,
            height: moreSize.height
        )
    }

    @objc private func textDidScroll(_ notification: Notification) {
        layoutLabels()
    }

    /// Height the paper needs to show all of its text at the given paper width.
    func paperHeight(fittingWidth width: CGFloat) -> CGFloat {
        if abs(textView.frame.width - width) > 0.5 {
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        }
        return metrics.stripHeight + textView.fittingHeight() + metrics.bottomPadding
    }

    // MARK: Content chrome

    func setBaseFontSize(_ size: CGFloat) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(size - 3, 9), weight: .regular)
        counterLabel.font = font
        moreLabel.font = font
        layoutLabels()
    }

    /// Updates the "3/5" counter and returns the space to keep free at the end of the title line.
    func setCounter(_ count: TaskCount) -> CGFloat {
        hasCounter = count.hasTasks
        counterLabel.stringValue = count.hasTasks ? count.label : ""
        layoutLabels()
        return count.hasTasks ? counterLabel.frame.width + 8 : 0
    }

    /// Tells the view whether the text is taller than the paper.
    func setOverflowing(_ overflowing: Bool) {
        isOverflowing = overflowing
        refreshOverflow()
    }

    private func refreshOverflow() {
        let showsFade = isOverflowing && !isEditing
        scrollView.hasVerticalScroller = isOverflowing && isEditing
        overflowFade.isHidden = !showsFade
        relayout() // the footer appears or disappears
        guard showsFade else {
            moreLabel.isHidden = true
            return
        }
        // At rest the sticker always shows its beginning.
        textView.scroll(NSPoint.zero)
        let hidden = textView.lineCount(notFittingAbove: scrollView.contentSize.height)
        moreLabel.isHidden = hidden == 0
        moreLabel.stringValue = L10n.stickerMore(hidden)
        layoutLabels()
    }

    func setChromeVisible(_ visible: Bool) {
        showsChrome = visible
        menuButton.isHidden = !visible
        textView.emphasizesMarkers = visible
    }

    /// Point below the menu button, in this view's coordinates, where its menu opens.
    var menuAnchor: NSPoint {
        NSPoint(x: menuButton.frame.minX, y: menuButton.frame.maxY + 4)
    }

    // MARK: Appearance

    func applyColors(_ color: PaperColor) {
        let dark = effectiveAppearance.isDark
        let paper = color.paperColor(dark: dark)
        fillView.setColors(
            paper: paper,
            strip: color.stripColor(dark: dark),
            border: NSColor.black.withAlphaComponent(0.08),
            cornerRadius: metrics.cornerRadius
        )
        overflowFade.paperColor = paper
        counterLabel.textColor = color.textColor(alpha: 0.55)
        moreLabel.textColor = color.textColor(alpha: 0.55)
        menuButton.contentTintColor = color.textColor(alpha: 0.6)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        delegate?.rootViewDidChangeAppearance(self)
    }

    func setPaperOpacity(_ opacity: CGFloat, duration: TimeInterval, curve: MotionCurve) {
        fillView.setPaperOpacity(opacity, duration: duration, curve: curve)
    }

    func setShadow(_ spec: ShadowSpec, duration: TimeInterval, curve: MotionCurve) {
        shadowView.apply(spec, duration: duration, curve: curve)
    }

    func setTextOpacity(_ opacity: CGFloat, duration: TimeInterval, curve: MotionCurve) {
        guard duration > 0 else {
            scrollView.alphaValue = opacity
            counterLabel.alphaValue = opacity
            moreLabel.alphaValue = opacity
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = curve.timingFunction
            scrollView.animator().alphaValue = opacity
            counterLabel.animator().alphaValue = opacity
            moreLabel.animator().alphaValue = opacity
        }
    }

    // MARK: Mouse

    /// Outside editing the root view takes every click on the paper and sorts it by zone.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard paperRect.contains(local) else { return nil }
        if showsChrome, !menuButton.isHidden, menuButton.frame.contains(local) {
            return menuButton
        }
        if isEditing, scrollView.frame.contains(local) {
            return super.hitTest(point)
        }
        return self
    }

    func zone(at point: NSPoint) -> StickerZone {
        if point.y < paperRect.minY + metrics.stripHeight {
            return .glueStrip
        }
        let inTextView = textView.convert(point, from: self)
        if let line = textView.todoLine(at: inTextView) {
            return .checkbox(line: line)
        }
        return .body(pointInTextView: inTextView)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        delegate?.rootView(self, mouseDownIn: zone(at: point), event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        delegate?.rootView(self, mouseDraggedWith: event)
    }

    override func mouseUp(with event: NSEvent) {
        delegate?.rootView(self, mouseUpWith: event)
    }

    @objc private func menuButtonClicked() {
        delegate?.rootViewDidClickMenuButton(self)
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// Cursor shapes per zone (spec 4.6). Only meaningful while the panel accepts clicks.
    private func updateCursor(at point: NSPoint) {
        guard showsChrome, paperRect.contains(point) else { return }
        if menuButton.frame.contains(point) {
            NSCursor.arrow.set()
            return
        }
        switch zone(at: point) {
        case .glueStrip:
            NSCursor.openHand.set()
        case .checkbox:
            NSCursor.pointingHand.set()
        case .body:
            // While editing, the text view manages its own I-beam.
            if !isEditing { NSCursor.iBeam.set() }
        }
    }
}
