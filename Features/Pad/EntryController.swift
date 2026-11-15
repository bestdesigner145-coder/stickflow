// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

/// The way in (spec 3, 4.1–4.3): the call zone at the screen edge, the tab that
/// marks it, the pad that comes out of the edge, and the draft a click on the
/// pad opens. The decisions are made by `CallEdge` and `EdgeIntentDetector` in
/// `StickflowCore`; this class shows what they decide.
@MainActor
final class EntryController: NSObject {
    private let tuning: Tuning
    private let preferences: Preferences
    private let displays: any ScreenGeometry
    private let stickers: StickerManager
    /// Takes dictated or typed text apart into a plan (spec 8).
    var structurer: any Structurer
    private let clock: any AppClock
    private var structuring: Task<Void, Never>?

    private var detector = EdgeIntentDetector()
    private(set) var phase: EdgeIntentDetector.Phase = .idle
    /// Hidden with the stickers while the screen is captured (spec 5.2).
    private var isSuppressed = false
    /// On: only samples marked as scripted are heard. For the self-check, whose
    /// scenario must not be disturbed by where the real cursor happens to be.
    var ignoresLivePointer = false

    private let tabPanel = EntryController.makePanel()
    private let tabView = EdgeTabView(frame: .zero)
    private let padPanel = EntryController.makePanel()
    private let padContainer = NSView(frame: .zero)
    private let padView = PadView(frame: .zero)
    private let glowView = PadGlowView(frame: .zero)
    let draft: DraftController

    /// Space around the pad inside its window, for the tilt and the glow.
    private static let padMargin: CGFloat = 24

    init(
        tuning: Tuning,
        preferences: Preferences,
        displays: any ScreenGeometry,
        stickers: StickerManager,
        structurer: any Structurer,
        dictation: Dictation,
        clock: any AppClock
    ) {
        self.structurer = structurer
        self.clock = clock
        self.tuning = tuning
        self.preferences = preferences
        self.displays = displays
        self.stickers = stickers
        draft = DraftController(tuning: tuning, preferences: preferences, dictation: dictation)
        super.init()

        tabPanel.contentView = tabView
        tabPanel.ignoresMouseEvents = true

        let content = NSView(frame: .zero)
        content.wantsLayer = true // opacity and rotation need layers
        content.addSubview(glowView)
        padContainer.addSubview(padView)
        content.addSubview(padContainer)
        padPanel.contentView = content
        padPanel.ignoresMouseEvents = true
        glowView.alphaValue = 0
        padView.onClick = { [weak self] in
            self?.openDraft(from: .pad)
        }

        draft.onStick = { [weak self] text, asIs in
            self?.stickDraft(text, asIs: asIs)
        }
        draft.onStop = { [weak self] in self?.stopStructuring() }
        draft.onRetry = { [weak self] in
            guard let self, case let .failed(text) = self.pending else { return }
            self.startStructuring(text)
        }
        draft.onStickAnyway = { [weak self] in
            guard let self, case let .failed(text) = self.pending else { return }
            self.commitAsIs(text)
        }
        draft.onUndoResult = { [weak self] in self?.undoResult() ?? false }
        draft.onCancel = { [weak self] text in
            self?.cancelDraft(text)
        }
    }

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        applySettings()
    }

    @objc private func screensDidChange() {
        applySettings()
    }

    // MARK: Geometry

    private struct Layout {
        let screen: ScreenLayout
        let edge: CallEdge
        let zone: CGRect
    }

    private var layout: Layout? {
        let all = displays.screens
        guard let target = displays.stickerScreen(preferredUUID: preferences.stickerDisplayUUID) else { return nil }
        let screen = ScreenLayout(frame: target.frame, visibleFrame: target.visibleFrame)
        let others = all.filter { $0 != target }.map { ScreenLayout(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let edge = CallEdge.choose(for: screen, others: others, preference: preferences.callEdge)
        let depth = CGFloat(edge.isStrict ? tuning.zoneDepthStrict : tuning.zoneDepthFree)
        let top = CGFloat(min(tuning.zoneTop, tuning.zoneBottom))
        let bottom = CGFloat(max(tuning.zoneTop, tuning.zoneBottom))
        let zone = edge.zone(on: screen, depth: depth, verticalRange: top...bottom)
        return Layout(screen: screen, edge: edge, zone: zone)
    }

    private var rules: EdgeIntentDetector.Rules {
        let strict = layout?.edge.isStrict ?? false
        return EdgeIntentDetector.Rules(
            maxSpeed: strict ? tuning.zoneMaxSpeedStrict : tuning.zoneMaxSpeedFree,
            peekDelay: strict ? tuning.zonePeekDelayStrict : tuning.zonePeekDelayFree,
            openDelay: strict ? tuning.zoneOpenDelayStrict : tuning.zoneOpenDelayFree,
            leaveDelay: tuning.zoneLeaveDelay,
            fastEntryRejects: tuning.zoneRejectsFastEntry
        )
    }

    /// The pad window: a strip at the edge. The pad slides inside it, so that
    /// nothing ever shows on a display next door.
    private func padWindowFrame(_ layout: Layout) -> CGRect {
        let size = CGFloat(tuning.padSize)
        let margin = Self.padMargin
        let width = CGFloat(tuning.padOpenReach) + margin
        let height = size + margin * 2
        let originX = layout.edge.side == .right ? layout.screen.frame.maxX - width : layout.screen.frame.minX
        return CGRect(x: originX, y: layout.zone.midY - height / 2, width: width, height: height)
    }

    /// Where the pad sits inside its window when it reaches `reach` points into the screen.
    private func padOrigin(reach: CGFloat, in window: CGRect, side: ScreenSide) -> CGPoint {
        let originX = side == .right ? window.width - reach : reach - CGFloat(tuning.padSize)
        return CGPoint(x: originX, y: Self.padMargin)
    }

    private func reach(for phase: EdgeIntentDetector.Phase) -> CGFloat {
        switch phase {
        case .idle: 0
        case .peek: CGFloat(tuning.padPeekReach)
        case .open: CGFloat(tuning.padOpenReach)
        }
    }

    /// The part of the pad that is on screen, in screen coordinates; `nil` while it is hidden.
    var visiblePadFrame: CGRect? {
        guard phase != .idle, let layout else { return nil }
        let window = padWindowFrame(layout)
        let origin = padOrigin(reach: reach(for: phase), in: window, side: layout.edge.side)
        let size = CGFloat(tuning.padSize)
        let pad = CGRect(x: window.minX + origin.x, y: window.minY + origin.y, width: size, height: size)
        return pad.intersection(window)
    }

    /// The middle of the pad's edge on screen: where peeled stickers fly to.
    var padPoint: CGPoint? {
        guard !isSuppressed, let layout else { return nil }
        let edgeX = layout.edge.side == .right ? layout.screen.frame.maxX : layout.screen.frame.minX
        return CGPoint(x: edgeX, y: layout.zone.midY)
    }

    /// The call zone in screen coordinates, for tests.
    var zoneFrame: CGRect? { layout?.zone }

    // MARK: Settings

    /// Re-reads screens, settings and `Tuning`.
    func applySettings() {
        guard let layout, !isSuppressed else {
            tabPanel.orderOut(nil)
            padPanel.orderOut(nil)
            return
        }
        tabView.paper = preferences.defaultColor
        padView.paper = preferences.defaultColor
        padView.edge = layout.edge.side
        padView.hiddenWidth = max(CGFloat(tuning.padSize - tuning.padOpenReach), 0)
        padView.labelFontSize = CGFloat(tuning.padLabelFontSize)
        padView.minimumLabelFontSize = CGFloat(tuning.padLabelMinFontSize)

        let tabSize = CGSize(width: tuning.tabWidth, height: tuning.tabHeight)
        let tabX = layout.edge.side == .right ? layout.screen.frame.maxX - tabSize.width : layout.screen.frame.minX
        tabPanel.setFrame(
            CGRect(x: tabX, y: layout.zone.midY - tabSize.height / 2, width: tabSize.width, height: tabSize.height),
            display: true
        )
        tabPanel.alphaValue = CGFloat(tuning.tabOpacity)
        if preferences.showsEdgeTab, phase == .idle {
            tabPanel.orderFrontRegardless()
        } else {
            tabPanel.orderOut(nil)
        }

        let window = padWindowFrame(layout)
        padPanel.setFrame(window, display: true)
        let size = CGFloat(tuning.padSize)
        padContainer.frame = CGRect(
            origin: padOrigin(reach: reach(for: phase), in: window, side: layout.edge.side),
            size: CGSize(width: size, height: size)
        )
        padView.frame = padContainer.bounds
        glowView.frame = CGRect(x: 0, y: 0, width: window.width, height: window.height)
    }

    /// Screen capture started or ended: the pad and the tab hide with the stickers.
    func setSuppressed(_ suppressed: Bool) {
        guard suppressed != isSuppressed else { return }
        isSuppressed = suppressed
        if suppressed {
            draft.close(animated: false)
            detector.reset()
            show(.idle, animated: false)
        }
        applySettings()
    }

    // MARK: Pointer

    /// True while the zone or the pad needs pointer samples even if the mouse is still.
    func needsPointer(at location: CGPoint) -> Bool {
        guard !isSuppressed, let layout else { return false }
        if detector.needsContinuousInput { return true }
        return layout.zone.insetBy(dx: -24, dy: -24).contains(location)
    }

    func pointerDidUpdate(_ sample: PointerSample, isScripted: Bool = false) {
        guard !isSuppressed, isScripted || !ignoresLivePointer, let layout else { return }
        let scene = EdgeIntentDetector.Scene(
            zone: layout.zone,
            padFrame: visiblePadFrame,
            distanceToEdge: layout.edge.distance(of: sample.location, on: layout.screen),
            holdsOpen: draft.isOpen
        )
        let input = EdgeIntentDetector.Input(location: sample.location, isMouseDown: sample.isMouseDown, time: sample.time)
        let next = detector.update(input, scene: scene, rules: rules)
        if next != phase {
            show(next, animated: true)
        }
        // Only the paper takes clicks; the glow and the margins let them through.
        if phase != .idle {
            padPanel.ignoresMouseEvents = !(visiblePadFrame?.contains(sample.location) ?? false)
        }
    }

    // MARK: Showing the pad

    private func show(_ newPhase: EdgeIntentDetector.Phase, animated: Bool) {
        phase = newPhase
        guard let layout, !isSuppressed || newPhase == .idle else { return }
        let window = padWindowFrame(layout)
        let target = padOrigin(reach: reach(for: newPhase), in: window, side: layout.edge.side)
        let tilt: CGFloat = newPhase == .peek ? CGFloat(tuning.padPeekRotation) * (layout.edge.side == .right ? 1 : -1) : 0
        let base: Double = switch newPhase {
        case .idle: tuning.padHideDuration
        case .peek: tuning.padPeekDuration
        case .open: tuning.padOpenDuration
        }
        let duration = animated ? tuning.scaled(base) : 0

        if newPhase != .idle {
            padPanel.orderFrontRegardless()
            tabPanel.orderOut(nil)
        } else {
            padPanel.ignoresMouseEvents = true
        }

        let glowAlpha: CGFloat = newPhase == .idle ? 0 : 1
        guard duration > 0 else {
            padContainer.setFrameOrigin(target)
            padContainer.frameCenterRotation = tilt
            glowView.alphaValue = glowAlpha
            finishShowing(newPhase)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = MotionCurve.drawer.timingFunction
            padContainer.animator().setFrameOrigin(target)
            padContainer.animator().frameCenterRotation = tilt
            glowView.animator().alphaValue = glowAlpha
        }, completionHandler: { [self] in
            MainActor.assumeIsolated {
                self.finishShowing(newPhase)
            }
        })
    }

    private func finishShowing(_ shown: EdgeIntentDetector.Phase) {
        // The pad may have been called again while it was hiding.
        guard shown == .idle, phase == .idle else { return }
        padPanel.orderOut(nil)
        if preferences.showsEdgeTab, !isSuppressed, layout != nil {
            tabPanel.orderFrontRegardless()
        }
    }

    // MARK: Draft

    enum DraftOrigin {
        /// A click on the pad: the sheet is torn off.
        case pad
        /// The hotkey or the menu bar: no paper theatre (spec 6.7).
        case shortcut
    }

    /// The quick-input hotkey and "New Sticker": opens the draft, or closes an open one.
    func toggleDraft() {
        if draft.isOpen {
            draft.cancel()
        } else {
            openDraft(from: .shortcut)
        }
    }

    func openDraft(from origin: DraftOrigin) {
        guard !draft.isOpen, !isSuppressed, let layout else { return }
        // The pad stays out for as long as the draft is open.
        detector.forceOpen()
        show(.open, animated: origin == .pad || phase != .open)

        clearPending()
        // "Add to sticker" is offered only when there is one (spec 4.3).
        draft.allowsAppend = stickers.topController != nil
        let window = padWindowFrame(layout)
        let padLeft = layout.edge.side == .right
            ? window.maxX - CGFloat(tuning.padOpenReach)
            : window.minX + CGFloat(tuning.padOpenReach)
        draft.open(
            besidePadEdgeX: padLeft,
            side: layout.edge.side,
            centerY: layout.zone.midY,
            within: layout.screen.visibleFrame,
            fromPad: origin == .pad
        )
        stickers.pointerNeedsAttention()
    }

    // MARK: From the draft to a sticker (spec 4.3, 8)

    /// What the draft is waiting for after Return.
    private enum Pending {
        case nothing
        /// A structurer is at work on this text.
        case structuring(String)
        /// The result is on show; it is stuck when the preview ends.
        case preview(text: String, plan: NotePlan)
        /// The structurer failed on this text; the user is asked what to do.
        case failed(String)

        var text: String? {
            switch self {
            case .nothing: nil
            case let .structuring(text), let .failed(text), let .preview(text, _): text
            }
        }
    }

    private var pending = Pending.nothing
    private var previewTimer: Timer?

    /// Return takes the text apart first; ⌘Return, or text that is a list already,
    /// is stuck as it is.
    private func stickDraft(_ text: String, asIs: Bool) {
        switch pending {
        case let .preview(original, plan):
            // Return or the tick while the result is shown: no more waiting.
            commit(plan, text: original)
        case .structuring, .failed:
            break
        case .nothing:
            if asIs || PlainTextPlan.looksStructured(text) {
                commitAsIs(text)
            } else {
                startStructuring(text)
            }
        }
    }

    private func startStructuring(_ text: String) {
        var draftRequest = StructureRequest(text: text, locale: .current, now: clock.now)
        draftRequest.ambiguousHoursAreAfternoon = tuning.rulesAssumeAfternoon
        let request = draftRequest
        let structurer = self.structurer
        let limit = structurer.isLocal ? tuning.structureTimeoutLocal : tuning.structureTimeoutCloud
        pending = .structuring(text)
        draft.showStructuring()
        structuring?.cancel()
        structuring = Task { [weak self] in
            let outcome = await Self.run(structurer, request, limit: limit)
            guard let self, !Task.isCancelled, self.draft.isOpen, case .structuring = self.pending else { return }
            switch outcome {
            case let .success(plan) where !plan.isEmpty:
                self.showResult(plan, text: text)
            case .success:
                // There was nothing to take apart: the text is stuck as it was written.
                self.commitAsIs(text)
            case let .failure(error) where (error as? StructurerError) == .nothingToDo:
                self.commitAsIs(text)
            case .failure:
                self.pending = .failed(text)
                self.draft.showFailure()
            }
        }
    }

    /// The structurer's answer, or a failure once `limit` seconds have passed (spec 8.1).
    private nonisolated static func run(
        _ structurer: any Structurer,
        _ request: StructureRequest,
        limit: TimeInterval
    ) async -> Result<NotePlan, any Error> {
        await withTaskGroup(of: Result<NotePlan, any Error>.self) { group in
            group.addTask {
                do {
                    return try await .success(structurer.structure(request).normalized())
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(limit, 0) * 1_000_000_000))
                return .failure(StructurerError.timedOut)
            }
            let first = await group.next() ?? .failure(StructurerError.timedOut)
            group.cancelAll()
            return first
        }
    }

    /// Shows the result in the draft, then sticks it (spec 4.3, "Готово").
    private func showResult(_ plan: NotePlan, text: String) {
        let delay = tuning.scaled(tuning.structuredPreviewDuration)
        guard delay > 0 else {
            commit(plan, text: text)
            return
        }
        pending = .preview(text: text, plan: plan)
        draft.showResult(plan.previewLines(includingTitle: !draft.isAppending))
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case let .preview(text, plan) = self.pending else { return }
                self.commit(plan, text: text)
            }
        }
    }

    private func clearPending() {
        structuring?.cancel()
        structuring = nil
        previewTimer?.invalidate()
        previewTimer = nil
        pending = .nothing
    }

    /// "Stop" while the text is being taken apart: back to writing, the text is as it was.
    private func stopStructuring() {
        guard case .structuring = pending else { return }
        clearPending()
        draft.showWriting()
    }

    /// ⌘Z while the result is shown: the original text comes back.
    private func undoResult() -> Bool {
        guard case let .preview(text, _) = pending else { return false }
        clearPending()
        draft.showWriting(restoring: text)
        return true
    }

    private func commit(_ plan: NotePlan, text: String) {
        let isAppending = draft.isAppending
        clearPending()
        if isAppending, let target = stickers.topController {
            draft.close(animated: true)
            stickers.append(plan, to: target)
            stickers.pointerNeedsAttention()
        } else {
            stick(PlainTextPlan.Result(title: plan.title, blocks: plan.blocks()), rawInput: text)
        }
    }

    /// Sticks the text line by line, without a structurer.
    private func commitAsIs(_ text: String) {
        let lines = PlainTextPlan.make(from: text, plainLineKind: tuning.newLineAfterTitleIsTodo ? .todo : .text)
        guard draft.isAppending, stickers.topController != nil else {
            clearPending()
            stick(lines, rawInput: text)
            return
        }
        // Added to a sticker, every line is an item of its own.
        let items = ([lines.title] + lines.blocks.map(\.text))
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { NotePlan.Item(text: $0) }
        commit(NotePlan(title: "", sections: [NotePlan.Section(items: items)]), text: text)
    }

    private func stick(_ plan: PlainTextPlan.Result, rawInput text: String) {
        let draftFrame = draft.frameOnScreen
        draft.close(animated: true)
        stickers.stick(plan, rawInput: text, flyingFrom: draftFrame)
        stickers.pointerNeedsAttention()
    }

    private func cancelDraft(_ shown: String) {
        // While a result is on show the draft holds the result, not what was written.
        let text = pending.text ?? shown
        clearPending()
        let plan = PlainTextPlan.make(from: text, plainLineKind: tuning.newLineAfterTitleIsTodo ? .todo : .text)
        draft.close(animated: true)
        stickers.keepDraft(plan, rawInput: text)
        stickers.pointerNeedsAttention()
    }

    #if DEBUG
    /// For the self-check's snapshots.
    var padSnapshotView: NSView { padView }
    var padWindowFrameForSnapshot: CGRect { padPanel.frame }
    #endif

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        return panel
    }
}
