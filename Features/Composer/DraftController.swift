// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

/// The draft: a new sticker being written, not stuck yet (spec 4.3).
///
/// It opens beside the pad, never in the middle of the screen. Return sticks it,
/// Shift-Return makes a new line, Esc closes it and keeps the text as a draft.
/// Voice and structuring arrive in stage 3; the microphone is drawn but idle.
@MainActor
final class DraftController: NSObject, NSTextViewDelegate {
    /// Return or the tick: stick this text.
    /// The second value is true for "stick as it is" (⌘Return), false for
    /// "take apart and stick" (Return, the tick).
    var onStick: ((String, Bool) -> Void)?
    /// Esc: close; the text is kept as a draft.
    var onCancel: ((String) -> Void)?

    private let tuning: Tuning
    private let preferences: Preferences
    private let panel = DraftPanel.make()
    let rootView: DraftView

    private var anchorEdgeX: CGFloat = 0
    private var side: ScreenSide = .right
    private var centerY: CGFloat = 0
    private var bounds = CGRect.zero
    private var isClosing = false

    init(tuning: Tuning, preferences: Preferences) {
        self.tuning = tuning
        self.preferences = preferences
        rootView = DraftView(frame: NSRect(x: 0, y: 0, width: 232, height: 160))
        super.init()
        panel.contentView = rootView
        rootView.textView.delegate = self
        rootView.textView.onSubmit = { [weak self] in self?.submit() }
        rootView.textView.onSubmitAsIs = { [weak self] in self?.submit(asIs: true) }
        rootView.textView.onCancel = { [weak self] in self?.cancel() }
        rootView.stickButton.onClick = { [weak self] in self?.submit() }

        // An empty draft must not hang around once the user has moved on.
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: panel
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceDidChange(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
    }

    @objc private func panelDidResignKey(_ notification: Notification) {
        attentionDidLeave()
    }

    @objc private func activeSpaceDidChange(_ notification: Notification) {
        attentionDidLeave()
    }

    /// While on, losing the keyboard does not close the draft: a system dialog
    /// of our own making (the microphone permission) is in front.
    var keepsOpenWithoutFocus = false

    /// The keyboard went to another window, or the user switched to another
    /// desktop. An empty draft closes and leaves nothing behind. A draft with text
    /// stays where it is, unless the Tuning switch says to put it away as a draft.
    func attentionDidLeave() {
        guard isOpen, !keepsOpenWithoutFocus else { return }
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isEmpty || tuning.draftWithTextClosesOnFocusLoss else { return }
        cancel()
    }

    var isOpen: Bool {
        panel.isVisible && !isClosing
    }

    var text: String {
        rootView.textView.string
    }

    /// Where the draft is on screen.
    var frameOnScreen: CGRect {
        panel.frame
    }

    private var width: CGFloat {
        switch preferences.sizeClass {
        case .small: CGFloat(tuning.widthSmall)
        case .medium: CGFloat(tuning.widthMedium)
        case .large: CGFloat(tuning.widthLarge)
        }
    }

    /// Opens an empty draft next to the pad.
    /// - Parameters:
    ///   - besidePadEdgeX: screen x of the pad's inner edge.
    ///   - centerY: the pad's vertical centre; the draft is centred on it.
    ///   - bounds: the area the draft must stay inside.
    ///   - fromPad: the sheet was torn off by a click (grows from the pad) or
    ///     called by a shortcut (just appears, spec 6.7).
    func open(besidePadEdgeX: CGFloat, side: ScreenSide, centerY: CGFloat, within bounds: CGRect, fromPad: Bool) {
        anchorEdgeX = besidePadEdgeX
        self.side = side
        self.centerY = centerY
        self.bounds = bounds
        isClosing = false

        rootView.paper = preferences.defaultColor
        rootView.textView.string = ""
        rootView.refresh()
        layoutPanel()

        let duration = tuning.scaled(fromPad ? tuning.draftFromPadDuration : tuning.draftFromHotkeyDuration)
        let startScale = CGFloat(fromPad ? tuning.draftFromPadStartScale : tuning.draftFromHotkeyStartScale)
        let reduceMotion = tuning.reduceMotion
        panel.alphaValue = duration > 0 ? 0 : 1
        panel.orderFrontRegardless()
        // Key without activating the app: the app in front stays in front.
        panel.makeKey()
        panel.makeFirstResponder(rootView.textView)
        guard duration > 0 else { return }
        if !reduceMotion {
            rootView.animateScale(from: startScale, to: 1, duration: duration, curve: fromPad ? .drawer : .easeOut)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = (fromPad ? MotionCurve.drawer : MotionCurve.easeOut).timingFunction
            panel.animator().alphaValue = 1
        }
    }

    /// Return, ⌘Return or the tick. Does nothing while the draft is empty.
    /// While on, the draft is being taken apart: it accepts no second Return.
    var isBusy = false {
        didSet { rootView.stickButton.isEnabled = !isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func submit(asIs: Bool = false) {
        guard isOpen, !isBusy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onStick?(text, asIs)
    }

    /// Esc, or the hotkey pressed again.
    func cancel() {
        guard isOpen else { return }
        onCancel?(text)
    }

    func close(animated: Bool) {
        guard panel.isVisible, !isClosing else { return }
        let duration = animated ? tuning.scaled(tuning.draftFromHotkeyDuration) : 0
        // Set first: leaving the screen takes the keyboard away, and that must not
        // be read as the user turning away from an open draft.
        isClosing = true
        guard duration > 0 else {
            panel.orderOut(nil)
            isClosing = false
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = MotionCurve.easeOut.timingFunction
            panel.animator().alphaValue = 0
        }, completionHandler: { [self] in
            MainActor.assumeIsolated {
                self.finishClosing()
            }
        })
    }

    private func finishClosing() {
        // The draft may have been opened again while it was fading out.
        guard isClosing else { return }
        isClosing = false
        // Leaving the screen gives the keyboard back to the app in front.
        panel.orderOut(nil)
    }

    func textDidChange(_ notification: Notification) {
        rootView.refresh()
        layoutPanel()
    }

    /// The draft grows with its text between the two limits, centred on the pad.
    private func layoutPanel() {
        let sheetWidth = width
        let needed = rootView.height(fittingWidth: sheetWidth)
        let height = min(max(needed, CGFloat(tuning.draftMinHeight)), CGFloat(tuning.draftMaxHeight))
        let gap = CGFloat(tuning.draftGap)
        let originX = side == .right ? anchorEdgeX - gap - sheetWidth : anchorEdgeX + gap
        var frame = CGRect(x: originX, y: centerY - height / 2, width: sheetWidth, height: height)
        if !bounds.isEmpty {
            frame = StickerGeometry.clamped(frame, within: bounds)
        }
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }
}

/// A panel that takes the keyboard without activating the app.
final class DraftPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func make() -> DraftPanel {
        let panel = DraftPanel(
            contentRect: NSRect(x: 0, y: 0, width: 232, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        return panel
    }
}

/// The sheet of the draft: the question, the text, the microphone and the tick.
final class DraftView: NSView {
    let textView = DraftTextView(frame: .zero)
    let stickButton = HandIconButton(icon: .check, label: L10n.draftStick)
    private let microphone = HandIconButton(icon: .microphone, label: L10n.draftDictate)
    private let titleLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView(frame: .zero)

    var paper: PaperColor = .default {
        didSet { applyColors() }
    }

    private static let padding: CGFloat = 14
    private static let headerHeight: CGFloat = 44
    private static let footerHeight: CGFloat = 40

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        titleLabel.stringValue = L10n.draftTitle
        titleLabel.font = HandFont.font(size: 22)
        titleLabel.lineBreakMode = .byTruncatingTail

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.placeholder = L10n.draftPlaceholder

        // Voice arrives in stage 3.
        microphone.isEnabled = false

        addSubview(titleLabel)
        addSubview(scrollView)
        addSubview(microphone)
        addSubview(stickButton)
        applyColors()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The tick is live only when there is something to stick.
    func refresh() {
        stickButton.isEnabled = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        textView.needsDisplay = true
    }

    /// Height the sheet needs to show all of its text at `width`.
    func height(fittingWidth width: CGFloat) -> CGFloat {
        let textWidth = width - Self.padding * 2
        guard let container = textView.textContainer, let manager = textView.layoutManager else {
            return Self.headerHeight + Self.footerHeight
        }
        container.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let textHeight = ceil(manager.usedRect(for: container).height) + textView.textContainerInset.height * 2
        // Room for the placeholder's two lines while the draft is empty.
        return Self.headerHeight + max(textHeight, 44) + Self.footerHeight
    }

    override func layout() {
        super.layout()
        let padding = Self.padding
        titleLabel.frame = NSRect(x: padding, y: 10, width: bounds.width - padding * 2, height: 30)
        scrollView.frame = NSRect(
            x: padding,
            y: Self.headerHeight,
            width: bounds.width - padding * 2,
            height: max(bounds.height - Self.headerHeight - Self.footerHeight, 0)
        )
        let iconSize: CGFloat = 24
        let iconY = bounds.height - Self.footerHeight + (Self.footerHeight - iconSize) / 2 - 2
        microphone.frame = NSRect(x: padding - 4, y: iconY, width: iconSize, height: iconSize)
        stickButton.frame = NSRect(x: bounds.width - padding - iconSize + 4, y: iconY, width: iconSize, height: iconSize)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func applyColors() {
        let text = paper.textColor()
        titleLabel.textColor = paper.textColor(alpha: 0.72)
        textView.textColor = text
        textView.insertionPointColor = text
        textView.placeholderColor = paper.textColor(alpha: 0.4)
        microphone.tint = paper.textColor(alpha: 0.75)
        stickButton.tint = paper.textColor(alpha: 0.85)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let sheet = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 3, yRadius: 3)
        paper.paperColor(dark: effectiveAppearance.isDark).setFill()
        sheet.fill()
        NSColor.black.withAlphaComponent(0.08).setStroke()
        sheet.lineWidth = 0.5
        sheet.stroke()
    }
}

/// The draft's plain text field with its keys (spec 4.3).
final class DraftTextView: NSTextView {
    var onSubmit: (() -> Void)?
    /// ⌘Return: stick the text as it is, without taking it apart.
    var onSubmitAsIs: (() -> Void)?
    var onCancel: (() -> Void)?
    var placeholder = ""
    var placeholderColor = NSColor.placeholderTextColor

    /// Key positions, so that shortcuts work on any layout.
    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let escape: UInt16 = 53
        static let keyA: UInt16 = 0
        static let keyZ: UInt16 = 6
        static let keyX: UInt16 = 7
        static let keyC: UInt16 = 8
        static let keyV: UInt16 = 9
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case KeyCode.escape:
            onCancel?()
        case KeyCode.returnKey, KeyCode.enter:
            if hasMarkedText() {
                super.keyDown(with: event) // the input method is still composing
            } else if flags.contains(.shift) {
                insertText("\n", replacementRange: selectedRange())
            } else {
                onSubmit?()
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// The app has no main menu, so the editing shortcuts are handled here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        if flags == .command {
            switch event.keyCode {
            case KeyCode.keyA: selectAll(nil)
            case KeyCode.keyC: copy(nil)
            case KeyCode.keyX: cut(nil)
            case KeyCode.keyV: pasteAsPlainText(nil)
            case KeyCode.keyZ: undoManager?.undo()
            case KeyCode.returnKey, KeyCode.enter: onSubmitAsIs?()
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        if flags == [.command, .shift], event.keyCode == KeyCode.keyZ {
            undoManager?.redo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: placeholderColor,
        ]
        let origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        let rect = NSRect(origin: origin, size: NSSize(width: bounds.width - origin.x * 2, height: bounds.height))
        (placeholder as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attributes)
    }
}

/// A small button drawn "by hand": a 1.5 pt line with round ends and no fill (spec 6.5).
final class HandIconButton: NSView {
    enum Icon {
        case microphone
        case check
    }

    var onClick: (() -> Void)?

    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : 0.3
            setAccessibilityEnabled(isEnabled)
        }
    }

    var tint = NSColor.labelColor {
        didSet { needsDisplay = true }
    }

    private let icon: Icon

    init(icon: Icon, label: String) {
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isEnabled { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Drawn on a 24 pt grid with the origin at the bottom left.
        let scale = min(bounds.width, bounds.height) / 24
        let path = NSBezierPath()
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: bounds.minX + x * scale, y: bounds.minY + y * scale)
        }
        switch icon {
        case .check:
            // A tick with a slight sag, as a pen would leave it.
            path.move(to: point(5.2, 12.4))
            path.curve(to: point(10.1, 6.4), controlPoint1: point(6.9, 10.8), controlPoint2: point(8.8, 8.3))
            path.curve(to: point(19.2, 17.8), controlPoint1: point(12.6, 10.9), controlPoint2: point(15.8, 15.2))
        case .microphone:
            // The capsule, a touch uneven.
            path.move(to: point(9.2, 13.1))
            path.curve(to: point(9.4, 18.2), controlPoint1: point(9.0, 14.9), controlPoint2: point(9.1, 16.8))
            path.curve(to: point(14.7, 18.0), controlPoint1: point(10.2, 21.3), controlPoint2: point(14.1, 21.2))
            path.curve(to: point(14.8, 13.0), controlPoint1: point(15.0, 16.5), controlPoint2: point(15.0, 14.6))
            path.curve(to: point(9.2, 13.1), controlPoint1: point(14.2, 9.9), controlPoint2: point(9.9, 10.1))
            // The holder.
            path.move(to: point(6.3, 13.6))
            path.curve(to: point(17.8, 13.4), controlPoint1: point(6.9, 5.9), controlPoint2: point(17.3, 6.0))
            // The stem and the foot.
            path.move(to: point(12.0, 7.9))
            path.line(to: point(12.1, 4.6))
            path.move(to: point(8.9, 4.4))
            path.line(to: point(15.3, 4.6))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        tint.setStroke()
        path.stroke()
    }
}
