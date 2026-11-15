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
    typealias Mode = StickerStateMachine.Mode

    private(set) var sticker: Sticker
    let panel: StickerPanel
    let rootView: StickerRootView
    weak var manager: StickerManager?

    private let tuning: Tuning
    private let preferences: Preferences
    private let clock: any AppClock

    /// Decides the mode from what the pointer and the edit key do.
    private var machine = StickerStateMachine()
    var mode: Mode { machine.mode }
    private(set) var isClosed = false
    /// Peeled off and flying away; the window closes when the animation ends.
    private(set) var isLeaving = false
    private var isDragging = false
    private var isMenuOpen = false
    /// Flying from the draft to its place (spec 4.4).
    private(set) var isAirborne = false
    private let motion = FrameAnimator()
    /// The corner is being pulled (spec 4.10).
    private(set) var isPeeling = false
    private var peelStartMouse = CGPoint.zero
    private var peelTrail: [(point: CGPoint, time: TimeInterval)] = []
    private var peelPull = CGSize.zero

    private var dragStartMouse = CGPoint.zero
    private var dragStartOrigin = CGPoint.zero
    private var clickMonitors: [Any] = []

    // MARK: Lifecycle

    init(sticker: Sticker, tuning: Tuning, preferences: Preferences, clock: any AppClock) {
        self.sticker = sticker
        self.tuning = tuning
        self.preferences = preferences
        self.clock = clock
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

    /// Puts the sticker on screen.
    /// - Parameter animated: a sticker that was not visible grows from 0.96 and
    ///   fades in, its shadow with it (spec 6.7).
    func show(animated: Bool = false) {
        guard !isClosed, !isLeaving else { return }
        guard animated, !panel.isVisible else {
            panel.orderFrontRegardless()
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = tuning.scaled(reduceMotion ? tuning.reducedMotionFade : tuning.appearDuration)
        let targetAlpha = mode == .faded ? CGFloat(tuning.fadedOpacity) : 1
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if !reduceMotion {
            rootView.animateScale(
                from: CGFloat(tuning.appearStartScale),
                to: 1,
                duration: duration,
                curve: .easeOut
            )
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = MotionCurve.easeOut.timingFunction
            panel.animator().alphaValue = targetAlpha
        }
    }

    func hide() {
        guard !isClosed, !isLeaving else { return }
        settleFlight()
        cancelPeel()
        endEditing()
        panel.orderOut(nil)
    }

    var isOnScreen: Bool {
        !isClosed && !isLeaving && panel.isVisible
    }

    /// Takes the sticker off the screen for good (spec 4.10, 6.7): it flies towards
    /// `edgeX`, shrinks and fades, then its window closes. The caller has already
    /// saved the model.
    /// - Parameter edgeX: screen x of the edge to fly to; `nil` just fades.
    /// - Parameters:
    ///   - target: screen point the sticker flies to (the pad); `nil` just fades.
    ///   - byGesture: torn off by its corner, so it turns a little as it goes.
    ///   - turnsLeft: which way it turns.
    func peelAway(towards target: CGPoint?, byGesture: Bool = false, turnsLeft: Bool = false) {
        guard !isClosed, !isLeaving else { return }
        settleFlight()
        motion.cancel()
        isPeeling = false
        isLeaving = true
        removeClickMonitors()
        cancelIdleTimer()
        rootView.delegate = nil
        panel.ignoresMouseEvents = true
        guard panel.isVisible else {
            close()
            return
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let moving = byGesture ? tuning.peelGestureDuration : tuning.peelDuration
        let duration = tuning.scaled(reduceMotion ? tuning.reducedMotionFade : moving)
        let curve: MotionCurve = reduceMotion ? .ease : .easeInOut
        let destination: NSRect?
        if !reduceMotion, let target {
            let turn = byGesture ? CGFloat(tuning.peelRotation) * (turnsLeft ? 1 : -1) : 0
            rootView.animateScale(
                from: 1,
                to: CGFloat(tuning.peelEndScale),
                rotation: turn,
                duration: duration,
                curve: curve,
                keepsFinalState: true
            )
            destination = panel.frame.offsetBy(dx: target.x - panel.frame.midX, dy: target.y - panel.frame.midY)
        } else {
            destination = nil
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = curve.timingFunction
            if let destination {
                panel.animator().setFrame(destination, display: false)
            }
            panel.animator().alphaValue = 0
        }, completionHandler: { [self] in
            MainActor.assumeIsolated {
                self.close()
            }
        })
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        motion.cancel()
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
            floatsAcrossSpaces: tuning.spacesBehaviorTransient,
            hideFromScreenCapture: preferences.hideFromScreenCapture
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

    /// Shows the state machine's mode after it changed.
    private func modeDidChange(from previous: Mode) {
        let current = machine.mode
        guard current != previous else { return }
        setIgnoresMouse(!(current == .editMode || current == .editing))
        applyMode(from: previous, animated: true)
    }

    private func setIgnoresMouse(_ ignores: Bool) {
        if panel.ignoresMouseEvents != ignores {
            panel.ignoresMouseEvents = ignores
        }
    }

    private func applyMode(from previous: Mode?, animated: Bool) {
        // In the user's hands, or in the air on its way to its place: opaque, with a wide shadow.
        let isInHand = mode == .editMode || mode == .editing
        let isLifted = isInHand || isAirborne
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

        // A long sticker scrolled with the edit key returns to its beginning at rest.
        rootView.setChromeVisible(isInHand, scrollResetDuration: duration)
        rootView.setPaperOpacity(CGFloat(paperOpacity), duration: duration, curve: curve)
        rootView.setTextOpacity(CGFloat(textOpacity), duration: duration, curve: curve)
        rootView.setShadow(shadowSpec, duration: duration, curve: curve)
        // With the edit key held the corner lifts a little: this is where the sticker peels off.
        if !isPeeling {
            let hint = mode == .editMode ? -CGFloat(tuning.peelCornerHint) : 0
            rootView.setCornerPull(CGSize(width: hint, height: hint))
        }

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

    /// The shadow for the current state and theme (spec 6.2).
    private var shadowSpec: ShadowSpec {
        let isLifted = mode == .editMode || mode == .editing || isAirborne
        let darkBoost = rootView.effectiveAppearance.isDark ? tuning.darkShadowMultiplier : 1.0
        if isLifted {
            return ShadowSpec(
                offsetY: CGFloat(tuning.liftedShadowOffset),
                blur: CGFloat(tuning.liftedShadowBlur),
                opacity: CGFloat(min(tuning.liftedShadowOpacity * darkBoost, 1))
            )
        }
        return ShadowSpec(
            offsetY: CGFloat(tuning.restShadowOffset),
            blur: CGFloat(tuning.restShadowBlur),
            opacity: CGFloat(min(tuning.restShadowOpacity * darkBoost, 1))
        )
    }

    // MARK: Sticking (spec 4.4)

    /// Flies the sticker from where the draft was to its place and lands it there
    /// with a squash, a settling shadow and a ring of air.
    /// - Parameter start: the draft's frame on screen; the flight starts at its top left corner.
    func flyIn(from start: CGRect) {
        guard !isClosed, !isLeaving else { return }
        let duration = tuning.scaled(tuning.flightDuration)
        guard duration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            // Reduce Motion: a cross-fade instead of the flight and the impact.
            show(animated: true)
            return
        }
        let margin = rootView.metrics.margin
        let destination = panel.frame.origin
        let paperTopLeft = CGPoint(x: start.minX, y: start.maxY)
        let origin = CGPoint(x: paperTopLeft.x - margin, y: paperTopLeft.y - panel.frame.height + margin)

        isAirborne = true
        applyMode(from: nil, animated: false)
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        rootView.animateScale(
            from: 1,
            to: CGFloat(tuning.flightScale),
            duration: min(duration, tuning.scaled(0.1)),
            curve: .easeOut,
            keepsFinalState: true
        )
        let lift = CGFloat(tuning.flightLift)
        motion.run(duration: duration, step: { [weak self] elapsed in
            guard let self else { return }
            let progress = MotionCurve.easeInOut.value(at: elapsed / duration)
            self.panel.setFrameOrigin(FlightPath.point(from: origin, to: destination, progress: progress, lift: lift))
        }, completion: { [weak self] in
            self?.land(at: destination)
        })
    }

    /// Ends a flight at once: the sticker is in its place, without the impact
    /// (spec 6.7: any action of the user finishes an animation).
    func settleFlight() {
        guard isAirborne else { return }
        isAirborne = false // `land` then skips the impact
        motion.finish()
    }

    private func land(at destination: CGPoint) {
        let withImpact = isAirborne
        isAirborne = false
        panel.setFrameOrigin(destination)
        guard withImpact else {
            rootView.removeScaleAnimation()
            applyMode(from: nil, animated: false)
            return
        }
        let impact = tuning.scaled(tuning.impactDuration)
        rootView.animateScale(
            through: [CGFloat(tuning.flightScale), CGFloat(tuning.impactSquash), 1],
            duration: impact,
            curve: .easeOut
        )
        // The shadow lands with the paper: wide and soft becomes close and sharp.
        applyMode(from: .editMode, animated: true)
        rootView.playAirRing(
            reach: CGFloat(tuning.airRingReach),
            opacity: Float(tuning.airRingOpacity),
            duration: tuning.scaled(tuning.airRingDuration)
        )
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        manager?.pointerNeedsAttention()
    }

    // MARK: Peeling by the corner (spec 4.10)

    /// The corner was grabbed at `location` (screen coordinates).
    func beginPeel(at location: CGPoint, time: TimeInterval) {
        guard !isClosed, !isLeaving, !isPeeling else { return }
        settleFlight()
        motion.cancel()
        isPeeling = true
        peelStartMouse = location
        peelTrail = [(location, time)]
        let hint = -CGFloat(tuning.peelCornerHint)
        peelPull = CGSize(width: hint, height: hint)
        NSCursor.closedHand.set()
    }

    /// The corner follows the cursor one to one.
    func updatePeel(to location: CGPoint, time: TimeInterval) {
        guard isPeeling else { return }
        peelTrail.append((location, time))
        if peelTrail.count > 12 { peelTrail.removeFirst(peelTrail.count - 12) }
        let hint = -CGFloat(tuning.peelCornerHint)
        // Screen y grows upwards, the view's y grows downwards.
        peelPull = CGSize(
            width: hint + location.x - peelStartMouse.x,
            height: hint - (location.y - peelStartMouse.y)
        )
        rootView.setCornerPull(peelPull)
    }

    /// The corner was let go: far or fast enough and the sticker comes off,
    /// otherwise the corner springs back.
    func endPeel(at location: CGPoint, time: TimeInterval) {
        guard isPeeling else { return }
        updatePeel(to: location, time: time)
        let distance = Double(hypot(location.x - peelStartMouse.x, location.y - peelStartMouse.y))
        let speed = PeelGesture.releaseSpeed(trail: peelTrail)
        let gesture = PeelGesture(distanceThreshold: tuning.peelDistance, speedThreshold: tuning.peelSpeed)
        if gesture.comesOff(distance: distance, speed: speed), let manager {
            manager.peel(self, byGesture: true, turnsLeft: location.x < peelStartMouse.x)
            return
        }
        snapCornerBack()
    }

    /// Lets go of the corner without peeling, e.g. when the sticker is hidden mid-gesture.
    func cancelPeel() {
        guard isPeeling else { return }
        motion.cancel()
        isPeeling = false
        applyMode(from: nil, animated: false)
    }

    private func snapCornerBack() {
        let from = peelPull
        let hint = mode == .editMode ? -CGFloat(tuning.peelCornerHint) : 0
        let spring = Spring(duration: tuning.scaled(tuning.peelSnapBackDuration), bounce: tuning.peelSnapBackBounce)
        motion.run(duration: spring.settlingTime, step: { [weak self] elapsed in
            guard let self else { return }
            let progress = CGFloat(spring.value(at: elapsed))
            self.rootView.setCornerPull(CGSize(
                width: from.width + (hint - from.width) * progress,
                height: from.height + (hint - from.height) * progress
            ))
        }, completion: { [weak self] in
            guard let self else { return }
            self.isPeeling = false
            self.machine.cancelPendingRelease()
            self.applyMode(from: nil, animated: false)
            self.manager?.pointerNeedsAttention()
        })
    }

    // MARK: Pointer

    /// True while this sticker needs 60 Hz pointer samples.
    func wantsPointerUpdates(at location: CGPoint) -> Bool {
        guard isOnScreen else { return false }
        if isDragging || isPeeling || machine.needsContinuousInput {
            return true
        }
        let reach = CGFloat(tuning.pointerPollProximity)
        return paperFrame.insetBy(dx: -reach, dy: -reach).contains(location)
    }

    /// Turns what the pointer does into input for the state machine (in
    /// `StickflowCore`, where it is unit-tested) and shows the mode it answers with.
    func pointerDidUpdate(_ sample: PointerSample) {
        guard isOnScreen, !isDragging, !isPeeling, !isAirborne, !isMenuOpen else { return }

        let paper = paperFrame
        let proximity = CGFloat(tuning.editKeyProximity)
        let input = StickerStateMachine.Input(
            isOver: paper.contains(sample.location),
            isNear: paper.insetBy(dx: -proximity, dy: -proximity).contains(sample.location),
            isEditKeyDown: sample.modifiers.contains(preferences.editKey.flag),
            isMouseDown: sample.isMouseDown,
            time: sample.time
        )
        let rules = StickerStateMachine.Rules(
            fadeEnabled: preferences.fadeEnabled,
            releaseGrace: tuning.editKeyReleaseGrace,
            hintDwell: tuning.hintDwell,
            suppressEditWhileMouseDown: tuning.suppressEditWhileMouseDown,
            keyMustBePressedAtSticker: tuning.editRequiresKeyPressOverSticker
        )

        let previous = machine.mode
        let outcome = machine.pointerMoved(input, rules: rules)
        if machine.mode == .editing {
            // Clickable only over the paper, so the transparent shadow margin
            // never swallows a click meant for the app underneath.
            setIgnoresMouse(!input.isNear)
        }
        modeDidChange(from: previous)
        if outcome.hidesHint {
            manager?.hideHint()
        }
        if outcome.showsHint {
            manager?.showEditHintIfNeeded(near: sample.location)
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
        let previous = machine.mode
        machine.beginEditing()
        modeDidChange(from: previous)

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
            // A non-activating panel keeps keyboard focus until another window takes
            // it; hand it back to the app the user was working in.
            if let manager {
                manager.returnKeyboardFocus(from: self)
            } else {
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }

        let previous = machine.mode
        machine.endEditing()
        modeDidChange(from: previous)

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
        sticker.updatedAt = clock.now
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
        settleFlight()
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
        let isDark = rootView.effectiveAppearance.isDark
        for color in PaperColor.allCases {
            let item = NSMenuItem(title: L10n.name(of: color), action: #selector(pickColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color.rawValue
            item.state = color == sticker.color ? .on : .off
            item.image = Self.swatch(for: color, dark: isDark)
            colorMenu.addItem(item)
        }
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)
        menu.addItem(.separator())

        // There is no "Delete" here: a sticker always goes to history first (spec 4.10).
        let peelItem = NSMenuItem(title: L10n.stickerMenuPeel, action: #selector(peelFromMenu), keyEquivalent: "")
        peelItem.target = self
        menu.addItem(peelItem)

        isMenuOpen = true
        menu.popUp(positioning: nil, at: rootView.menuAnchor, in: rootView)
        isMenuOpen = false
        machine.cancelPendingRelease()
        manager?.pointerNeedsAttention()
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let color = PaperColor(stored: raw) else { return }
        sticker.color = color
        sticker.updatedAt = clock.now
        applySettings()
        manager?.persist(self)
    }

    @objc private func peelFromMenu() {
        manager?.peel(self)
    }

    /// A circle in the paper colour, shown next to the colour's name in the menu.
    private static func swatch(for color: PaperColor, dark: Bool) -> NSImage {
        let rgb = color.palette.paper(dark: dark)
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            NSColor(rgb: rgb).setFill()
            circle.fill()
            // Paper colours are close to the menu background; the outline keeps the circle readable.
            NSColor.labelColor.withAlphaComponent(0.3).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
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
        case .corner:
            beginPeel(at: NSEvent.mouseLocation, time: event.timestamp)
        case let .checkbox(line):
            // Ticks the task without entering editing (spec 4.6).
            view.textView.toggleDone(line: line)
        case let .body(pointInTextView):
            beginEditing(at: pointInTextView)
        }
    }

    func rootView(_ view: StickerRootView, mouseDraggedWith event: NSEvent) {
        if isPeeling {
            updatePeel(to: NSEvent.mouseLocation, time: event.timestamp)
            return
        }
        guard isDragging else { return }
        // A drag that has started continues even if the edit key is released (spec 4.6).
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(CGPoint(
            x: dragStartOrigin.x + mouse.x - dragStartMouse.x,
            y: dragStartOrigin.y + mouse.y - dragStartMouse.y
        ))
    }

    func rootView(_ view: StickerRootView, mouseUpWith event: NSEvent) {
        if isPeeling {
            endPeel(at: NSEvent.mouseLocation, time: event.timestamp)
            return
        }
        guard isDragging else { return }
        isDragging = false
        machine.cancelPendingRelease()
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

    func rootViewDidClickCloseButton(_ view: StickerRootView) {
        manager?.peel(self)
    }

    func rootViewDidChangeAppearance(_ view: StickerRootView) {
        guard !isClosed else { return }
        // The system theme changed. The window stays where it is; paper, text and
        // shadow flow into the new colours together with the system (spec 6.7).
        let duration = panel.isVisible ? tuning.scaled(tuning.themeTransitionDuration) : 0
        view.applyColors(sticker.color, duration: duration, curve: .ease)
        view.setShadow(shadowSpec, duration: duration, curve: .ease)
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
