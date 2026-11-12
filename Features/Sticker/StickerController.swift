// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

/// One sticker on screen: its window, its state machine and its link to the model.
///
/// States (spec 4.6, 4.7):
/// - `rest`: translucent, clicks pass through.
/// - `faded`: the cursor is over it without the edit key, so it gets out of the way.
/// - `editMode`: the edit key is held over it; opaque and clickable.
/// - `editing`: the text has keyboard focus; stays interactive without the key.
@MainActor
final class StickerController: NSObject {
    enum Mode: Equatable {
        case rest
        case faded
        case editMode
        case editing
    }

    private(set) var sticker: Sticker
    let panel: StickerPanel
    let rootView: StickerRootView
    weak var manager: StickerManager?

    private let tuning: Tuning
    private let preferences: Preferences

    private(set) var mode: Mode = .rest
    private(set) var isClosed = false
    private var isDragging = false
    private var isMenuOpen = false

    /// When the cursor entered the paper; drives the fade delay and the hint.
    private var hoverSince: TimeInterval?
    /// When edit mode ends after the key was released or the cursor left.
    private var releaseDeadline: TimeInterval?
    private var wasNear = false
    /// False when the edit key was already down as the cursor arrived (debug rule, see `Tuning`).
    private var isArmed = true
    private var hintShownForThisHover = false

    private var dragStartMouse = CGPoint.zero
    private var dragStartOrigin = CGPoint.zero
    private var clickMonitors: [Any] = []

    // MARK: Lifecycle

    init(sticker: Sticker, tuning: Tuning, preferences: Preferences) {
        self.sticker = sticker
        self.tuning = tuning
        self.preferences = preferences
        panel = StickerPanel.make()
        rootView = StickerRootView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        super.init()

        panel.contentView = rootView
        rootView.delegate = self
        rootView.textView.blockDelegate = self
        rootView.textView.placeholder = L10n.stickerPlaceholder
        reloadEditor()
        applySettings()
    }

    func show() {
        guard !isClosed else { return }
        panel.orderFrontRegardless()
    }

    func hide() {
        guard !isClosed else { return }
        endEditing()
        panel.orderOut(nil)
    }

    var isOnScreen: Bool {
        !isClosed && panel.isVisible
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        removeClickMonitors()
        cancelIdleTimer()
        rootView.delegate = nil
        rootView.textView.teardown()
        panel.orderOut(nil)
        panel.close()
    }

    /// Changes the model. Callers persist afterwards.
    func updateSticker(_ change: (inout Sticker) -> Void) {
        change(&sticker)
    }

    // MARK: Geometry (screen coordinates, y grows upwards)

    private var margin: CGFloat { CGFloat(tuning.shadowMargin) }

    /// The paper without the transparent shadow margin.
    var paperFrame: CGRect {
        panel.frame.insetBy(dx: margin, dy: margin)
    }

    var paperWidth: CGFloat {
        switch preferences.sizeClass {
        case .small: CGFloat(tuning.widthSmall)
        case .medium: CGFloat(tuning.widthMedium)
        case .large: CGFloat(tuning.widthLarge)
        }
    }

    func setPaperFrame(_ paper: CGRect) {
        panel.setFrame(paper.insetBy(dx: -margin, dy: -margin), display: true)
    }

    /// Fits the paper to its text. The top-left corner stays where it is.
    func resizeToFit() {
        let current = paperFrame
        let width = paperWidth
        let needed = rootView.paperHeight(fittingWidth: width)
        let height = min(max(needed, CGFloat(tuning.minPaperHeight)), CGFloat(tuning.maxPaperHeight))
        let target = CGRect(x: current.minX, y: current.maxY - height, width: width, height: height)
        if abs(target.width - current.width) > 0.25 || abs(target.height - current.height) > 0.25 {
            setPaperFrame(target)
        }
        rootView.setOverflowing(needed > height + 0.5)
    }

    // MARK: Settings and appearance

    /// Re-reads everything that depends on `Tuning`, `Preferences` and the sticker's colour.
    func applySettings() {
        guard !isClosed else { return }
        rootView.metrics = StickerRootView.Metrics(
            margin: margin,
            stripHeight: CGFloat(tuning.glueStripHeight),
            cornerRadius: CGFloat(tuning.paperCornerRadius),
            bottomPadding: 8
        )
        panel.applySystemBehavior(
            showOverFullscreen: preferences.showOverFullscreen,
            usesWindowLevel: tuning.fullscreenUsesWindowLevel,
            hideFromScreenSharing: preferences.hideFromScreenSharing
        )

        let textView = rootView.textView
        textView.kindAfterTitle = tuning.newLineAfterTitleIsTodo ? .todo : .text
        var style = textView.style
        style.baseFontSize = CGFloat(preferences.fontSize)
        style.color = sticker.color
        style.doneOpacity = CGFloat(tuning.doneTextOpacity)
        textView.style = style

        rootView.setBaseFontSize(CGFloat(preferences.fontSize))
        rootView.applyColors(sticker.color)
        updateCounter()
        resizeToFit()
        applyMode(from: nil, animated: false)
    }

    private func reloadEditor() {
        rootView.textView.load(EditorDocument(title: sticker.title, blocks: sticker.blocks))
    }

    private func updateCounter() {
        let reserve = rootView.setCounter(sticker.taskCount)
        if abs(rootView.textView.style.titleTailReserve - reserve) > 0.5 {
            rootView.textView.style.titleTailReserve = reserve
        }
    }

    private func setMode(_ newMode: Mode, animated: Bool = true) {
        guard newMode != mode else { return }
        let previous = mode
        mode = newMode
        setIgnoresMouse(!(newMode == .editMode || newMode == .editing))
        applyMode(from: previous, animated: animated)
    }

    private func setIgnoresMouse(_ ignores: Bool) {
        if panel.ignoresMouseEvents != ignores {
            panel.ignoresMouseEvents = ignores
        }
    }

    private func applyMode(from previous: Mode?, animated: Bool) {
        let isLifted = mode == .editMode || mode == .editing
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

        let restPaperOpacity = reduceTransparency ? 1.0 : preferences.paperOpacity
        let paperOpacity = isLifted ? 1.0 : restPaperOpacity
        let textOpacity = isLifted ? 1.0 : tuning.restTextOpacity
        let windowAlpha = mode == .faded ? tuning.fadedOpacity : 1.0

        let baseDuration: Double
        if mode == .faded {
            baseDuration = tuning.fadeOutDuration
        } else if isLifted {
            baseDuration = tuning.editModeInDuration
        } else if previous == .faded {
            baseDuration = tuning.fadeInDuration
        } else {
            baseDuration = tuning.editModeOutDuration
        }
        let duration = animated ? tuning.scaled(baseDuration) : 0
        let curve = MotionCurve.easeOut

        let darkBoost = rootView.effectiveAppearance.isDark ? tuning.darkShadowMultiplier : 1.0
        let shadow = isLifted
            ? ShadowSpec(
                offsetY: CGFloat(tuning.liftedShadowOffset),
                blur: CGFloat(tuning.liftedShadowBlur),
                opacity: CGFloat(min(tuning.liftedShadowOpacity * darkBoost, 1))
            )
            : ShadowSpec(
                offsetY: CGFloat(tuning.restShadowOffset),
                blur: CGFloat(tuning.restShadowBlur),
                opacity: CGFloat(min(tuning.restShadowOpacity * darkBoost, 1))
            )

        rootView.setChromeVisible(isLifted)
        rootView.setPaperOpacity(CGFloat(paperOpacity), duration: duration, curve: curve)
        rootView.setTextOpacity(CGFloat(textOpacity), duration: duration, curve: curve)
        rootView.setShadow(shadow, duration: duration, curve: curve)

        if duration > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = curve.timingFunction
                panel.animator().alphaValue = CGFloat(windowAlpha)
            }
        } else {
            panel.alphaValue = CGFloat(windowAlpha)
        }
    }

    // MARK: Pointer

    /// True while this sticker needs 60 Hz pointer samples.
    func wantsPointerUpdates(at location: CGPoint) -> Bool {
        guard isOnScreen else { return false }
        if isDragging || mode == .faded || mode == .editMode || hoverSince != nil || releaseDeadline != nil {
            return true
        }
        let reach = CGFloat(tuning.pointerPollProximity)
        return paperFrame.insetBy(dx: -reach, dy: -reach).contains(location)
    }

    func pointerDidUpdate(_ sample: PointerSample) {
        guard isOnScreen, !isDragging, !isMenuOpen else { return }

        let paper = paperFrame
        let proximity = CGFloat(tuning.editKeyProximity)
        let isOver = paper.contains(sample.location)
        let isNear = paper.insetBy(dx: -proximity, dy: -proximity).contains(sample.location)
        let isKeyDown = sample.modifiers.contains(preferences.editKey.flag)

        // Debug rule: the key only counts when pressed with the cursor already here.
        if !isKeyDown {
            isArmed = true
        } else if isNear, !wasNear, tuning.editRequiresKeyPressOverSticker {
            isArmed = false
        }
        wasNear = isNear

        switch mode {
        case .editing:
            // Clickable only over the paper, so the transparent shadow margin
            // never swallows a click meant for the app underneath.
            setIgnoresMouse(!isNear)

        case .editMode:
            if isKeyDown, isNear {
                releaseDeadline = nil
                return
            }
            let deadline = releaseDeadline ?? sample.time + tuning.editKeyReleaseGrace
            releaseDeadline = deadline
            if sample.time >= deadline {
                releaseDeadline = nil
                hoverSince = isOver ? sample.time : nil
                hintShownForThisHover = true
                setMode(.rest)
            }

        case .rest, .faded:
            let isBlockedByMouse = tuning.suppressEditWhileMouseDown && sample.isMouseDown
            if isKeyDown, isNear, isArmed, !isBlockedByMouse {
                hoverSince = nil
                manager?.hideHint()
                setMode(.editMode)
                return
            }
            guard isOver else {
                hoverSince = nil
                hintShownForThisHover = false
                if mode == .faded { setMode(.rest) }
                return
            }
            let since = hoverSince ?? sample.time
            hoverSince = since
            let dwell = sample.time - since

            if preferences.fadeEnabled {
                if mode == .rest, dwell >= tuning.fadeDelay { setMode(.faded) }
            } else if mode == .faded {
                setMode(.rest)
            }
            if !isKeyDown, !hintShownForThisHover, dwell >= tuning.hintDwell {
                hintShownForThisHover = true
                manager?.showEditHintIfNeeded(near: sample.location)
            }
        }
    }

    // MARK: Editing

    /// Gives the text keyboard focus. The app itself is not activated (spec 4.8).
    func beginEditing(at pointInTextView: NSPoint?) {
        guard !isClosed, mode != .editing else { return }
        manager?.willBeginEditing(self)
        manager?.hideHint()

        let textView = rootView.textView
        panel.allowsKeyStatus = true
        rootView.isEditing = true
        textView.isEditable = true
        textView.isSelectable = true
        releaseDeadline = nil
        hoverSince = nil
        setMode(.editing)

        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(textView)

        let length = (textView.string as NSString).length
        let index = pointInTextView.map { min(textView.characterIndexForInsertion(at: $0), length) } ?? length
        textView.setSelectedRange(NSRange(location: index, length: 0))

        resizeToFit()
        // Editing can start with the cursor far away (hotkey). The panel must not
        // catch clicks in its transparent margin until the cursor comes back.
        let proximity = CGFloat(tuning.editKeyProximity)
        setIgnoresMouse(!paperFrame.insetBy(dx: -proximity, dy: -proximity).contains(NSEvent.mouseLocation))
        installClickMonitors()
        restartIdleTimer()
        manager?.pointerNeedsAttention()
    }

    /// Leaves editing: commits the text, drops empty lines and returns keyboard focus.
    func endEditing() {
        guard mode == .editing else { return }
        removeClickMonitors()
        cancelIdleTimer()

        let textView = rootView.textView
        commitEditorContent(dropEmpty: true)
        textView.isEditable = false
        textView.isSelectable = false
        panel.makeFirstResponder(nil)
        rootView.isEditing = false
        panel.allowsKeyStatus = false
        if panel.isKeyWindow, panel.isVisible {
            // A non-activating panel keeps keyboard focus until another window takes it.
            // Re-ordering the panel hands focus back to the app the user was working in.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }

        hoverSince = nil
        releaseDeadline = nil
        setMode(.rest)

        if sticker.isBlank {
            manager?.discard(self)
            return
        }
        reloadEditor()
        updateCounter()
        resizeToFit()
        manager?.persist(self)
        manager?.pointerNeedsAttention()
    }

    private func commitEditorContent(dropEmpty: Bool) {
        let result = rootView.textView.document.titleAndBlocks(dropEmpty: dropEmpty)
        guard result.title != sticker.title || result.blocks != sticker.blocks else { return }
        sticker.title = result.title
        sticker.blocks = result.blocks
        sticker.updatedAt = Date()
    }

    private func installClickMonitors() {
        removeClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        // A click in another app ends editing (spec 4.8).
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endEditing()
            }
        }
        if let global { clickMonitors.append(global) }

        // So does a click in another Stickflow window.
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let windowNumber = event.windowNumber
            MainActor.assumeIsolated {
                guard let self else { return }
                if windowNumber != self.panel.windowNumber {
                    self.endEditing()
                }
            }
            return event
        }
        if let local { clickMonitors.append(local) }
    }

    private func removeClickMonitors() {
        for monitor in clickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        clickMonitors.removeAll()
    }

    private func restartIdleTimer() {
        cancelIdleTimer()
        guard mode == .editing else { return }
        perform(#selector(idleTimeoutFired), with: nil, afterDelay: tuning.editingIdleTimeout)
    }

    private func cancelIdleTimer() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(idleTimeoutFired), object: nil)
    }

    @objc private func idleTimeoutFired() {
        endEditing()
    }

    // MARK: Moving

    private func beginDrag() {
        isDragging = true
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = panel.frame.origin
        NSCursor.closedHand.set()
    }

    // MARK: Menu

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let colorItem = NSMenuItem(title: L10n.stickerMenuPaperColor, action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for color in PaperColor.allCases {
            let item = NSMenuItem(title: L10n.name(of: color), action: #selector(pickColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color.rawValue
            item.state = color == sticker.color ? .on : .off
            colorMenu.addItem(item)
        }
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)
        menu.addItem(.separator())

        let peelItem = NSMenuItem(title: L10n.stickerMenuPeel, action: #selector(peelFromMenu), keyEquivalent: "")
        peelItem.target = self
        menu.addItem(peelItem)

        let deleteItem = NSMenuItem(title: L10n.stickerMenuDelete, action: #selector(deleteFromMenu), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)

        isMenuOpen = true
        menu.popUp(positioning: nil, at: rootView.menuAnchor, in: rootView)
        isMenuOpen = false
        releaseDeadline = nil
        manager?.pointerNeedsAttention()
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let color = PaperColor(rawValue: raw) else { return }
        sticker.color = color
        sticker.updatedAt = Date()
        applySettings()
        manager?.persist(self)
    }

    @objc private func peelFromMenu() {
        manager?.peel(self)
    }

    @objc private func deleteFromMenu() {
        manager?.delete(self)
    }
}

// MARK: - StickerRootViewDelegate

extension StickerController: StickerRootViewDelegate {
    func rootView(_ view: StickerRootView, mouseDownIn zone: StickerZone, event: NSEvent) {
        restartIdleTimer()
        switch zone {
        case .glueStrip:
            if event.clickCount >= 2 {
                // Double click on the glue strip: back to the default spot (spec 4.5).
                manager?.moveToDefaultAnchor(self)
            } else {
                beginDrag()
            }
        case .checkbox(let line):
            // Ticks the task without entering editing (spec 4.6).
            view.textView.toggleDone(line: line)
        case .body(let pointInTextView):
            beginEditing(at: pointInTextView)
        }
    }

    func rootView(_ view: StickerRootView, mouseDraggedWith event: NSEvent) {
        guard isDragging else { return }
        // A drag that has started continues even if the edit key is released (spec 4.6).
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(CGPoint(
            x: dragStartOrigin.x + mouse.x - dragStartMouse.x,
            y: dragStartOrigin.y + mouse.y - dragStartMouse.y
        ))
    }

    func rootView(_ view: StickerRootView, mouseUpWith event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        releaseDeadline = nil
        NSCursor.openHand.set()

        let origin = panel.frame.origin
        let distance = hypot(origin.x - dragStartOrigin.x, origin.y - dragStartOrigin.y)
        if distance > 0.5 {
            manager?.stickerDidMove(self)
        }
        manager?.pointerNeedsAttention()
    }

    func rootViewDidClickMenuButton(_ view: StickerRootView) {
        showMenu()
    }

    func rootViewDidChangeAppearance(_ view: StickerRootView) {
        guard !isClosed else { return }
        view.applyColors(sticker.color)
        applyMode(from: nil, animated: false)
    }
}

// MARK: - BlockTextViewDelegate

extension StickerController: BlockTextViewDelegate {
    func blockTextViewDidChangeContent(_ textView: BlockTextView) {
        commitEditorContent(dropEmpty: false)
        updateCounter()
        resizeToFit()
        restartIdleTimer()
        manager?.schedulePersist(self)
    }

    func blockTextViewDidRequestEndEditing(_ textView: BlockTextView) {
        endEditing()
    }

    func blockTextViewDidInteract(_ textView: BlockTextView) {
        restartIdleTimer()
    }

    func blockTextView(_ textView: BlockTextView, didRequestFontSizeChange delta: Int) {
        manager?.changeFontSize(by: delta)
    }
}
