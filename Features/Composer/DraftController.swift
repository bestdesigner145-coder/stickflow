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

    /// Voice into the draft (spec 7).
    let dictation: Dictation
    /// Whether the speech model is on this Mac; no microphone until it is (spec 18.1).
    let speech: SpeechSetup

    init(tuning: Tuning, preferences: Preferences, dictation: Dictation, speech: SpeechSetup) {
        self.tuning = tuning
        self.preferences = preferences
        self.dictation = dictation
        self.speech = speech
        rootView = DraftView(frame: NSRect(x: 0, y: 0, width: 232, height: 160))
        super.init()
        panel.contentView = rootView
        rootView.textView.delegate = self
        rootView.textView.onSubmit = { [weak self] in self?.submit() }
        rootView.textView.onSubmitAsIs = { [weak self] in self?.submit(asIs: true) }
        rootView.textView.onCancel = { [weak self] in self?.cancel() }
        rootView.stickButton.onClick = { [weak self] in
            guard let self else { return }
            if self.rootView.phase == .structuring {
                self.onStop?()
            } else {
                self.submit()
            }
        }
        rootView.retryButton.onClick = { [weak self] in self?.onRetry?() }
        rootView.stickAnywayButton.onClick = { [weak self] in self?.onStickAnyway?() }
        rootView.textView.onUndo = { [weak self] in self?.onUndoResult?() ?? false }
        rootView.onMicrophone = { [weak self] in
            guard let self, self.speech.isReady else { return }
            self.dictation.toggle()
        }
        // "Download" and "Try again" under the text: the user's own word (spec 0.8).
        rootView.onSpeechSetup = { [weak self] in self?.speech.start() }
        speech.observe { [weak self] in self?.speechDidChange() }
        rootView.textView.onSpace = { [weak self] in
            // Space stops a recording instead of typing a space (spec 4.3).
            guard let self, self.dictation.state == .recording else { return false }
            self.dictation.toggle()
            return true
        }
        dictation.onChange = { [weak self] in self?.dictationDidChange() }
        dictation.onText = { [weak self] text in self?.insertDictated(text) }

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
        // A draft that is listening is in use, wherever the keyboard is.
        guard isOpen, !keepsOpenWithoutFocus, !dictation.isBusy else { return }
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

    private func speechDidChange() {
        rootView.speech = speech.state
        if isOpen { layoutPanel() }
    }

    private func dictationDidChange() {
        // The permission dialogs take the keyboard; the draft must outlive them.
        let wasWaiting = keepsOpenWithoutFocus
        keepsOpenWithoutFocus = dictation.state == .preparing
        rootView.dictation = DictationStatus(
            state: dictation.state,
            elapsed: dictation.elapsed,
            level: dictation.level,
            message: dictation.message,
            isEnding: DictationClock.isEnding(elapsed: dictation.elapsed, limit: tuning.dictationLimit, warning: tuning.dictationWarning)
        )
        guard isOpen else { return }
        layoutPanel()
        if wasWaiting, !keepsOpenWithoutFocus, !panel.isKeyWindow {
            panel.makeKey()
            panel.makeFirstResponder(rootView.textView)
        }
    }

    /// What was said goes to the end of what is already there.
    private func insertDictated(_ text: String) {
        let view = rootView.textView
        let existing = view.string
        let needsSpace = !existing.isEmpty && !existing.hasSuffix("\n") && !existing.hasSuffix(" ")
        view.insertText((needsSpace ? " " : "") + text, replacementRange: NSRange(location: (existing as NSString).length, length: 0))
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

        dictation.cancel()
        rootView.setPhase(.writing)
        rootView.speechMegabytes = speech.megabytes
        rootView.speech = speech.state
        rootView.paper = preferences.defaultColor
        rootView.pulseDuration = tuning.reduceMotion ? 0 : tuning.scaled(tuning.dictationPulseDuration)
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
    /// "Stop" while the text is being taken apart.
    var onStop: (() -> Void)?
    /// "Try again" and "Stick" after a structurer failed.
    var onRetry: (() -> Void)?
    var onStickAnyway: (() -> Void)?
    /// ⌘Z while the result is shown; true means the original text came back.
    var onUndoResult: (() -> Bool)?

    var phase: DraftView.Phase { rootView.phase }

    func submit(asIs: Bool = false) {
        guard isOpen, phase == .writing || phase == .result, !dictation.isBusy else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onStick?(text, asIs)
    }

    /// The text is being taken apart: it dims, "Sorting…" and "Stop" appear.
    func showStructuring() {
        rootView.spinnerPeriod = tuning.reduceMotion ? 0 : tuning.scaled(tuning.spinnerPeriod)
        rootView.setPhase(.structuring)
        layoutPanel()
    }

    /// The structurer failed: "Stick as it is?" with two answers.
    func showFailure() {
        rootView.setPhase(.failed)
        layoutPanel()
    }

    /// The result, highlighted, in place of the text (spec 4.3, "Готово").
    func showResult(_ lines: [String]) {
        rootView.showResult(lines: lines)
        layoutPanel()
    }

    /// Back to writing; `text` puts the original text back after a result.
    func showWriting(restoring text: String? = nil) {
        rootView.setPhase(.writing, restoring: text)
        layoutPanel()
        if isOpen { panel.makeFirstResponder(rootView.textView) }
    }

    /// Esc, or the hotkey pressed again.
    func cancel() {
        guard isOpen else { return }
        onCancel?(text)
    }

    func close(animated: Bool) {
        guard panel.isVisible, !isClosing else { return }
        dictation.cancel()
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
    /// The microphone is offered: the speech model is on this Mac (spec 18.1).
    var showsMicrophone: Bool { !microphone.isHidden }
    private let titleLabel = NSTextField(labelWithString: "")
    /// The timer while recording, "Listening…" while recognising.
    private let statusLabel = NSTextField(labelWithString: "")
    /// What went wrong with the dictation and what to do about it.
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let levelBar = CALayer()

    var onMicrophone: (() -> Void)?

    /// What the draft is doing with the text after Return (spec 4.3).
    enum Phase: Equatable {
        case writing
        /// A structurer is at work.
        case structuring
        /// The structurer failed and the user is asked what to do.
        case failed
        /// The result is shown before it is stuck.
        case result
    }

    private(set) var phase = Phase.writing
    let retryButton = PaperTextButton(title: L10n.draftRetry)
    let stickAnywayButton = PaperTextButton(title: L10n.draftStickAsIs)
    private let spinner = SpinnerView(frame: .zero)

    /// In the microphone's place until the speech model is on this Mac (spec 18.1):
    /// "Getting recognition ready… 42 %", or a word to click that starts the download.
    let setupButton = PaperTextButton(title: "")
    var onSpeechSetup: (() -> Void)?

    var speech = SpeechSetup.State.ready {
        didSet {
            guard speech != oldValue else { return }
            applyPhase()
            needsLayout = true
        }
    }

    /// Megabytes of the speech model, for "Download".
    var speechMegabytes = 0

    /// Seconds per turn of the spinner; 0 leaves it standing.
    var spinnerPeriod: TimeInterval = 0

    func setPhase(_ new: Phase, restoring text: String? = nil) {
        phase = new
        if let text {
            textView.string = text
            // The marker of a result must not stay on the text that came back.
            let whole = NSRange(location: 0, length: (text as NSString).length)
            textView.textStorage?.removeAttribute(.backgroundColor, range: whole)
            textView.typingAttributes[.backgroundColor] = nil
        }
        applyPhase()
    }

    /// Shows the plan's lines in place of the text, highlighted like with a marker.
    func showResult(lines: [String]) {
        phase = .result
        textView.string = lines.joined(separator: "\n")
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.textStorage?.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.28), range: whole)
        applyPhase()
    }

    private func applyPhase() {
        let isWriting = phase == .writing
        textView.isEditable = isWriting
        textView.alphaValue = phase == .structuring ? 0.45 : 1
        microphone.isHidden = !(isWriting && speech == .ready)
        setupButton.isHidden = !(isWriting && speech != .ready)
        switch speech {
        case .ready: break
        case .missing: setupButton.set(title: L10n.speechDownload(megabytes: speechMegabytes), isLink: true)
        case let .downloading(percent): setupButton.set(title: L10n.speechPreparing(percent: percent), isLink: false)
        case .failed: setupButton.set(title: L10n.speechRetry, isLink: true)
        case .unsupported: setupButton.set(title: L10n.speechUnsupported, isLink: false)
        }
        stickButton.isHidden = phase == .failed
        stickButton.icon = phase == .structuring ? .stop : .check
        stickButton.setAccessibilityLabel(phase == .structuring ? L10n.draftStop : L10n.draftStick)
        retryButton.isHidden = phase != .failed
        stickAnywayButton.isHidden = phase != .failed
        spinner.isHidden = phase != .structuring
        spinner.setSpinning(phase == .structuring, period: spinnerPeriod)
        refresh()
        applyDictation()
    }

    /// What dictation is doing (spec 4.3).
    var dictation = DictationStatus() {
        didSet {
            if dictation != oldValue { applyDictation() }
        }
    }

    /// One beat of the microphone's pulse while it records; 0 for no pulse.
    var pulseDuration: TimeInterval = 0
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

        microphone.onClick = { [weak self] in self?.onMicrophone?() }
        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        messageLabel.font = NSFont.systemFont(ofSize: 11)
        messageLabel.isSelectable = false
        levelBar.cornerRadius = 1
        levelBar.isHidden = true
        layer?.addSublayer(levelBar)

        setupButton.isHidden = true
        setupButton.onClick = { [weak self] in self?.onSpeechSetup?() }
        retryButton.isHidden = true
        stickAnywayButton.isHidden = true
        spinner.isHidden = true

        addSubview(titleLabel)
        addSubview(scrollView)
        addSubview(messageLabel)
        addSubview(microphone)
        addSubview(setupButton)
        addSubview(spinner)
        addSubview(statusLabel)
        addSubview(retryButton)
        addSubview(stickAnywayButton)
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
        // "Stop" is always there to press; the tick needs something to stick.
        stickButton.isEnabled = phase == .structuring || !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        var textHeight = ceil(manager.usedRect(for: container).height) + textView.textContainerInset.height * 2
        // Room for the placeholder and the line about headings, points and tasks while the draft is empty.
        if textView.string.isEmpty { textHeight = max(textHeight, textView.emptyHeight(fittingWidth: textWidth)) }
        return Self.headerHeight + max(textHeight, 44) + messageHeight(fittingWidth: textWidth) + Self.footerHeight
    }

    override func layout() {
        super.layout()
        let padding = Self.padding
        titleLabel.frame = NSRect(x: padding, y: 10, width: bounds.width - padding * 2, height: 30)
        let footerTop = bounds.height - Self.footerHeight
        let noteHeight = messageHeight(fittingWidth: bounds.width - padding * 2)
        scrollView.frame = NSRect(
            x: padding,
            y: Self.headerHeight,
            width: bounds.width - padding * 2,
            height: max(footerTop - noteHeight - Self.headerHeight, 0)
        )
        messageLabel.frame = NSRect(x: padding, y: footerTop - noteHeight, width: bounds.width - padding * 2, height: noteHeight)
        let iconSize: CGFloat = 24
        let iconY = bounds.height - Self.footerHeight + (Self.footerHeight - iconSize) / 2 - 2
        microphone.frame = NSRect(x: padding - 4, y: iconY, width: iconSize, height: iconSize)
        stickButton.frame = NSRect(x: bounds.width - padding - iconSize + 4, y: iconY, width: iconSize, height: iconSize)
        spinner.frame = NSRect(x: padding, y: iconY + 5, width: 14, height: 14)
        let retrySize = retryButton.naturalSize
        retryButton.frame = NSRect(x: padding, y: iconY + 3, width: retrySize.width, height: retrySize.height)
        let anywaySize = stickAnywayButton.naturalSize
        stickAnywayButton.frame = NSRect(
            x: bounds.width - padding - anywaySize.width,
            y: iconY + 3,
            width: anywaySize.width,
            height: anywaySize.height
        )
        let statusX = microphone.frame.maxX + 6
        // In the microphone's place, as wide as the footer allows.
        let setupWidth = min(setupButton.naturalSize.width + 2, max(stickButton.frame.minX - 6 - padding, 0))
        setupButton.frame = NSRect(x: padding, y: iconY + 4, width: setupWidth, height: 18)
        statusLabel.frame = NSRect(x: statusX, y: iconY + 3, width: max(stickButton.frame.minX - 6 - statusX, 0), height: 18)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        levelBar.frame = NSRect(x: statusX, y: iconY + 23, width: Self.levelBarWidth * CGFloat(dictation.level), height: 2)
        CATransaction.commit()
    }

    private static let levelBarWidth: CGFloat = 44

    private func messageHeight(fittingWidth width: CGFloat) -> CGFloat {
        guard !messageLabel.stringValue.isEmpty, width > 0 else { return 0 }
        let size = messageLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 400)) ?? .zero
        return ceil(size.height) + 6
    }

    private func applyDictation() {
        let isRecording = dictation.state == .recording
        switch (phase, dictation.state) {
        case (.structuring, _): statusLabel.stringValue = L10n.draftStructuring
        case (_, .recording): statusLabel.stringValue = DictationClock.label(elapsed: dictation.elapsed)
        case (_, .recognizing): statusLabel.stringValue = L10n.dictationListening
        default: statusLabel.stringValue = ""
        }
        if phase == .failed {
            messageLabel.stringValue = L10n.draftFailed
        } else {
            // A failure is shown once the dictation is over.
            messageLabel.stringValue = (dictation.state == .idle ? dictation.message : nil) ?? ""
        }
        microphone.isEnabled = dictation.state == .idle || isRecording
        microphone.setAccessibilityLabel(isRecording ? L10n.draftStopDictation : L10n.draftDictate)
        levelBar.isHidden = !isRecording

        let pulseKey = "recording"
        if isRecording, pulseDuration > 0 {
            if microphone.layer?.animation(forKey: pulseKey) == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.45
                pulse.duration = pulseDuration
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                microphone.layer?.add(pulse, forKey: pulseKey)
            }
        } else {
            microphone.layer?.removeAnimation(forKey: pulseKey)
        }
        applyColors()
        needsLayout = true
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
        let isRecording = dictation.state == .recording
        microphone.tint = isRecording ? .systemRed : paper.textColor(alpha: 0.75)
        // Spec 7: the timer turns red before the limit.
        statusLabel.textColor = isRecording && dictation.isEnding ? .systemRed : paper.textColor(alpha: 0.72)
        messageLabel.textColor = paper.textColor(alpha: 0.62)
        setupButton.tint = paper.textColor(alpha: 0.62)
        retryButton.tint = paper.textColor(alpha: 0.7)
        stickAnywayButton.tint = paper.textColor(alpha: 0.9)
        spinner.tint = paper.textColor(alpha: 0.72)
        levelBar.backgroundColor = NSColor.systemRed.cgColor
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
    /// Space was pressed; true means it was used up and must not be typed.
    var onSpace: (() -> Bool)?
    /// ⌘Z; true means the owner undid something of its own.
    var onUndo: (() -> Bool)?
    var onCancel: (() -> Void)?
    var placeholder = ""
    var placeholderColor = NSColor.placeholderTextColor
    /// Space between the placeholder and the line about headings, points and tasks.
    private static let hintGap: CGFloat = 6

    private var placeholderAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: placeholderColor]
    }

    private func placeholderHeight(fittingWidth width: CGFloat) -> CGFloat {
        guard !placeholder.isEmpty, width > 0 else { return 0 }
        let rect = (placeholder as NSString).boundingRect(
            with: NSSize(width: width, height: 400), options: [.usesLineFragmentOrigin], attributes: placeholderAttributes
        )
        return ceil(rect.height)
    }

    /// Height of what an empty draft shows: the placeholder and the hint (spec 18.5).
    func emptyHeight(fittingWidth width: CGFloat) -> CGFloat {
        placeholderHeight(fittingWidth: width) + Self.hintGap + MarkupHint.height(fittingWidth: width) + textContainerInset.height * 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MarkupHint.follow(self)
    }

    /// Key positions, so that shortcuts work on any layout.
    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let escape: UInt16 = 53
        static let space: UInt16 = 49
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
        case KeyCode.space:
            if onSpace?() != true {
                super.keyDown(with: event)
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
            case KeyCode.keyZ:
                if onUndo?() != true { undoManager?.undo() }
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
        let origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        let width = bounds.width - origin.x * 2
        let rect = NSRect(origin: origin, size: NSSize(width: width, height: bounds.height))
        (placeholder as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: placeholderAttributes)
        // Spec 18.5: one small grey line, gone with the first character.
        let hintY = origin.y + placeholderHeight(fittingWidth: width) + Self.hintGap
        MarkupHint.draw(at: NSPoint(x: origin.x, y: hintY), width: width, color: placeholderColor.withAlphaComponent(0.32))
    }
}

/// A small button drawn "by hand": a 1.5 pt line with round ends and no fill (spec 6.5).
final class HandIconButton: NSView {
    enum Icon {
        case microphone
        case check
        case stop
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

    var icon: Icon {
        didSet { needsDisplay = true }
    }

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
        case .stop:
            // A square, not quite square.
            path.move(to: point(7.3, 7.5))
            path.line(to: point(16.8, 7.2))
            path.line(to: point(17.0, 16.7))
            path.line(to: point(7.1, 16.9))
            path.close()
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        tint.setStroke()
        path.stroke()
    }
}
