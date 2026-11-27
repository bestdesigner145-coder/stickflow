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
    /// Built anew for every request, so that a change of settings applies at once.
    private let makeStructurer: () -> any Structurer
    private var structurerOverride: (any Structurer)?
    /// The built-in model, whatever the settings say: "Yes" to "Sort it with the built-in model?".
    private let makeBuiltIn: () -> any Structurer
    /// Loads the built-in model and reads its rules while the draft is being written.
    private let primeBuiltIn: () -> Void
    private let models: ModelsSetup
    /// A sticker stuck as it was while the model was on its way; "Sort into tasks" once it is here (spec 18.10 A3).
    private weak var waitingForModel: StickerController?

    /// The structurer of the moment. Setting it pins one, for the self-check.
    var structurer: any Structurer {
        get { structurerOverride ?? makeStructurer() }
        set { structurerOverride = newValue }
    }

    /// Asks before text goes to a cloud provider (spec 8.1); replaced in tests.
    var confirmCloud: @MainActor (String) -> (allowed: Bool, remember: Bool) = { CloudConsent.ask(provider: $0) }
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
    private let padShadow = PadShadowView(frame: .zero)
    private let glowView = PadGlowView(frame: .zero)
    private var padTransition = 0
    let draft: DraftController
    /// Dictation into a sticker that is already there (spec 18.4).
    private(set) var voice: StickerVoice?

    /// Space around the pad inside its window, for the tilt, the shadow and the glow.
    private static let padMargin: CGFloat = 44

    init(
        tuning: Tuning,
        preferences: Preferences,
        displays: any ScreenGeometry,
        stickers: StickerManager,
        makeStructurer: @escaping () -> any Structurer,
        makeBuiltIn: @escaping () -> any Structurer,
        primeBuiltIn: @escaping () -> Void,
        dictation: Dictation,
        stickerDictation: Dictation,
        models: ModelsSetup,
        clock: any AppClock
    ) {
        self.makeStructurer = makeStructurer
        self.makeBuiltIn = makeBuiltIn
        self.primeBuiltIn = primeBuiltIn
        self.models = models
        self.clock = clock
        self.tuning = tuning
        self.preferences = preferences
        self.displays = displays
        self.stickers = stickers
        draft = DraftController(tuning: tuning, preferences: preferences, dictation: dictation, models: models)
        super.init()
        models.observe { [weak self] in self?.modelsDidChange() }
        let voice = StickerVoice(dictation: stickerDictation, stickers: stickers, models: models) { [weak self] text in
            await self?.plan(for: text) ?? nil
        }
        voice.makeEdit = { [weak self] request in
            await self?.stickerEdit(request) ?? nil
        }
        voice.providerName = { [weak self] in self?.preferences.structurerChoice.name ?? "" }
        // One microphone: the draft's dictation comes first.
        voice.isBlocked = { [weak self] in self?.draft.isOpen ?? false }
        self.voice = voice

        tabPanel.contentView = tabView
        tabPanel.ignoresMouseEvents = true

        let content = NSView(frame: .zero)
        content.wantsLayer = true // opacity and rotation need layers
        content.addSubview(glowView)
        padContainer.wantsLayer = true
        padContainer.addSubview(padShadow)
        padContainer.addSubview(padView)
        // The pad moves as a picture; it is drawn again only when it changes.
        padView.layerContentsRedrawPolicy = .onSetNeedsDisplay
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
        draft.onUseBuiltIn = { [weak self] in
            guard let self, case let .failed(text) = self.pending else { return }
            self.startStructuring(text, with: self.makeBuiltIn())
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
        padShadow.frame = padContainer.bounds
        padShadow.configure(radius: CGFloat(tuning.padShadowRadius), offsetY: CGFloat(tuning.padShadowOffset))
        padShadow.setOpacity(phase == .idle ? 0 : Float(tuning.padShadowOpacity), duration: 0, curve: .drawer)
        glowView.strength = CGFloat(tuning.padGlowOpacity)
        glowView.frame = CGRect(x: 0, y: 0, width: window.width, height: window.height)
        // On screen all the time, empty while the pad is in: bringing a window in
        // at the moment the pad starts to move costs the first frames (fix H5).
        padPanel.orderFrontRegardless()
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

    /// While the destination is already hidden, only paper still on screen can recall the pad.
    private var retreatingPadFrame: CGRect? {
        guard phase == .idle, preferences.smoothPadMotion, !tuning.reduceMotion,
              let layer = padContainer.layer, layer.animation(forKey: "slideMove") != nil,
              let shown = layer.presentation() else { return nil }
        let window = padPanel.frame
        return shown.frame.offsetBy(dx: window.minX, dy: window.minY).intersection(window)
    }

    /// True while the zone or the pad needs pointer samples even if the mouse is still.
    func needsPointer(at location: CGPoint) -> Bool {
        guard !isSuppressed, let layout else { return false }
        if detector.needsContinuousInput { return true }
        if retreatingPadFrame?.contains(location) == true { return true }
        return layout.zone.insetBy(dx: -24, dy: -24).contains(location)
    }

    func pointerDidUpdate(_ sample: PointerSample, isScripted: Bool = false) {
        guard !isSuppressed, isScripted || !ignoresLivePointer, let layout else { return }
        let scene = EdgeIntentDetector.Scene(
            zone: layout.zone,
            padFrame: visiblePadFrame ?? retreatingPadFrame,
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

    private func padCurve(for phase: EdgeIntentDetector.Phase) -> MotionCurve {
        if preferences.smoothPadMotion {
            return phase == .idle ? .padRetreat : .padReveal
        }
        return phase == .idle && tuning.padHideCurveReversed ? MotionCurve.drawer.reversed : .drawer
    }

    private func show(_ newPhase: EdgeIntentDetector.Phase, animated: Bool) {
        phase = newPhase
        guard let layout, !isSuppressed || newPhase == .idle else { return }
        let window = padWindowFrame(layout)
        let target = padOrigin(reach: reach(for: newPhase), in: window, side: layout.edge.side)
        // With "Reduce motion" the pad neither travels nor turns: it fades in and
        // out where it stands, with its shadow and the oval (spec 6.7, fix K1).
        let reduceMotion = tuning.reduceMotion
        let peekTilt = CGFloat(tuning.padPeekRotation) * (layout.edge.side == .right ? 1 : -1)
        let tilt: CGFloat = newPhase == .peek && !reduceMotion ? peekTilt : 0
        let base: Double = switch newPhase {
        case .idle: tuning.padHideDuration
        case .peek: tuning.padPeekDuration
        case .open: tuning.padOpenDuration
        }
        let scale = preferences.smoothPadMotion ? tuning.padGlideDurationScale : 1
        let duration = animated ? tuning.scaled(base * scale) : 0

        if newPhase != .idle {
            // Above the stickers that have appeared since; the window is on screen already.
            padPanel.orderFrontRegardless()
            tabPanel.orderOut(nil)
        } else {
            padPanel.ignoresMouseEvents = true
        }

        // The pad, its shadow and the oval move as layers on the render server, at
        // the display's own rate; the window stays where it is (spec 6.7 `drawer`, fix H5).
        let isOut = newPhase != .idle
        let curve = padCurve(for: newPhase)
        let fade = animated && reduceMotion ? tuning.scaled(tuning.padReduceMotionFade) : 0
        let time = reduceMotion ? fade : duration
        padTransition += 1
        let transition = padTransition
        CATransaction.begin()
        if time > 0 {
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.padTransition == transition else { return }
                    self.finishShowing(newPhase, target: target)
                }
            }
        }
        if reduceMotion {
            // Out: in place at once, then visible. Back: it fades where it is and
            // is put away when it has faded (`finishShowing`).
            if isOut || fade <= 0 {
                padContainer.slide(to: target, rotation: 0, duration: 0, curve: curve)
            }
            padContainer.fade(to: isOut || fade <= 0 ? 1 : 0, duration: fade, curve: .ease)
        } else {
            padContainer.fade(to: 1, duration: 0, curve: curve)
            padContainer.slide(to: target, rotation: tilt, duration: duration, curve: curve)
        }
        padShadow.setOpacity(isOut ? Float(tuning.padShadowOpacity) : 0, duration: time, curve: reduceMotion ? .ease : curve)
        glowView.fade(to: isOut ? 1 : 0, duration: time, curve: reduceMotion ? .ease : curve)
        CATransaction.commit()
        if time <= 0 { finishShowing(newPhase, target: target) }
    }

    private func finishShowing(_ shown: EdgeIntentDetector.Phase, target: CGPoint) {
        // The pad may have been called again while it was hiding.
        guard shown == .idle, phase == .idle else { return }
        if padContainer.alphaValue < 1 {
            // Faded out with "Reduce motion": put away, ready to fade in next time.
            padContainer.slide(to: target, rotation: 0, duration: 0, curve: .drawer)
            padContainer.alphaValue = 0
        }
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
        // One microphone: a dictation into a sticker gives way to the draft.
        voice?.cancel()
        // The model reads its rules while the user speaks: the answer then comes sooner.
        if preferences.structurerChoice == .local { primeBuiltIn() }
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

    /// The request for `text`: the titles on screen go along, so that the new one differs (spec 18.7).
    private func request(for text: String) -> StructureRequest {
        var request = StructureRequest(text: text, locale: .current, now: clock.now)
        request.ambiguousHoursAreAfternoon = tuning.rulesAssumeAfternoon
        request.takenTitles = stickers.controllers.filter { !$0.isClosed }.map(\.sticker.title)
        return request
    }

    private func limit(for structurer: any Structurer) -> TimeInterval {
        if structurer.id == "local" { return tuning.structureTimeoutBuiltIn }
        return structurer.isLocal ? tuning.structureTimeoutLocal : tuning.structureTimeoutCloud
    }

    private func startStructuring(_ text: String, with chosen: (any Structurer)? = nil) {
        let request = request(for: text)
        let structurer = chosen ?? self.structurer
        // Spec 8.1: nothing goes to a cloud provider before the user has said yes; and
        // nothing is asked before there is a key to send it with (spec 18.10 C2).
        let choice = preferences.structurerChoice
        let hasKey = !choice.needsKey || KeychainStore.has(choice.account)
        if !structurer.isLocal, hasKey, !preferences.cloudConsent.contains(structurer.id) {
            draft.keepsOpenWithoutFocus = true
            let answer = confirmCloud(structurer.displayName)
            draft.keepsOpenWithoutFocus = false
            guard answer.allowed else {
                clearPending()
                draft.showWriting()
                return
            }
            if answer.remember {
                preferences.cloudConsent.append(structurer.id)
                preferences.persist()
            }
        }
        let limit = limit(for: structurer)
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
            case let .failure(error):
                self.failed(text, error as? StructurerError)
            }
        }
    }

    /// Says why the text was not taken apart, and what can be done (spec 18.10 C2).
    private func failed(_ text: String, _ error: StructurerError?) {
        let provider = preferences.structurerChoice.name
        switch error {
        case .modelDownloading:
            // Spec 18.10 A3: stuck as it is now, taken apart once the model is here.
            commitAsIs(text)
            noteWaitingForModel()
            return
        case .missingKey: pending = .failed(text)
            draft.showFailure(L10n.structureNoKey(provider), retryable: false)
        case .rejectedKey: pending = .failed(text)
            draft.showFailure(L10n.structureBadKey(provider), retryable: false)
        case .offline: pending = .failed(text)
            draft.showFailure(L10n.structureOffline, offersBuiltIn: preferences.structurerChoice != .local)
        case .noCredit: pending = .failed(text)
            draft.showFailure(L10n.structureNoCredit(provider), retryable: false)
        case .unavailable: pending = .failed(text)
            draft.showFailure(L10n.structureUnavailable(provider), offersBuiltIn: preferences.structurerChoice != .local)
        case .noModel: pending = .failed(text)
            draft.showFailure(L10n.structureNoModel(provider), retryable: false)
        case .timedOut: pending = .failed(text)
            draft.showFailure(L10n.structureTimedOut)
        default: pending = .failed(text)
            draft.showFailure(L10n.draftFailed)
        }
    }

    /// The sticker just stuck waits for the model: a note under it, and "Sort into
    /// tasks" when the model is here (spec 18.10 A3).
    private func noteWaitingForModel() {
        guard let sticker = stickers.controllers.last(where: { !$0.isClosed }) else { return }
        waitingForModel = sticker
        if case .downloading = models.state {
            stickers.note(L10n.toastStructureLater, under: sticker)
        } else {
            // Nobody has asked for the models yet: the note offers them (spec 0.8).
            stickers.note(L10n.toastStructureLater, action: L10n.toastDownload, under: sticker, lasts: nil) { [weak self] in
                self?.models.start()
            }
        }
    }

    private func modelsDidChange() {
        guard models.isStructuringReady, let sticker = waitingForModel, !sticker.isClosed else { return }
        waitingForModel = nil
        stickers.note(L10n.toastStructureReady, action: L10n.toastStructure, under: sticker, lasts: nil) { [weak self, weak sticker] in
            guard let self, let sticker else { return }
            self.restructure(sticker)
        }
    }

    /// "Sort into tasks": the sticker's text as it was said, taken apart now.
    private func restructure(_ sticker: StickerController) {
        let text = sticker.sticker.rawInput ?? ""
        guard !text.isEmpty else { return }
        let builtIn = makeBuiltIn()
        var request = request(for: text)
        request.takenTitles.removeAll { $0 == sticker.sticker.title }
        let limit = limit(for: builtIn)
        Task { [weak self, weak sticker] in
            let outcome = await Self.run(builtIn, request, limit: limit)
            guard let self, let sticker, !sticker.isClosed, case let .success(plan) = outcome, !plan.isEmpty else { return }
            self.stickers.replace(plan, in: sticker)
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
                    let plan = try await structurer.structure(request).normalized()
                    return .success(plan.titled(apartFrom: request.takenTitles, at: request.now))
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
        draft.showResult(plan.previewLines())
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
        clearPending()
        stick(PlainTextPlan.Result(title: plan.title, blocks: plan.blocks()), rawInput: text)
    }

    /// Sticks the text line by line, without a structurer.
    private func commitAsIs(_ text: String) {
        let lines = PlainTextPlan.make(from: text, plainLineKind: tuning.newLineAfterTitleIsTodo ? .todo : .text)
        clearPending()
        stick(lines, rawInput: text)
    }

    /// A plan for text dictated into a sticker (spec 18.4); `nil` when the
    /// structurer failed or found nothing to do. No dialog is put over a sticker:
    /// a cloud provider that has not been allowed yet gives way to the rules.
    func plan(for text: String) async -> NotePlan? {
        let request = request(for: text)
        var structurer = self.structurer
        if !structurer.isLocal, !preferences.cloudConsent.contains(structurer.id) {
            structurer = makeBuiltIn()
        }
        let limit = limit(for: structurer)
        guard let plan = try? await Self.run(structurer, request, limit: limit).get(), !plan.isEmpty else { return nil }
        return plan
    }

    /// What was said into a sticker, as a model reads it (spec 18.22): commands
    /// for its lines, or new lines. `nil`: no model, the dictation is appended as before.
    func stickerEdit(_ request: StickerEditRequest) async -> Result<StickerEdit, any Error>? {
        var structurer = self.structurer
        if !structurer.isLocal, !preferences.cloudConsent.contains(structurer.id) {
            structurer = makeBuiltIn()
        }
        guard structurer.editsStickers else { return nil }
        return await Self.runEdit(structurer, request, limit: limit(for: structurer))
    }

    private nonisolated static func runEdit(
        _ structurer: any Structurer,
        _ request: StickerEditRequest,
        limit: TimeInterval
    ) async -> Result<StickerEdit, any Error> {
        await withTaskGroup(of: Result<StickerEdit, any Error>.self) { group in
            group.addTask {
                do {
                    return try await .success(structurer.edit(request))
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
    /// How far in time the pad's move is, 0…1; `nil` when it is not moving.
    var padMoveProgress: Double? {
        guard let layer = padContainer.layer, let move = layer.animation(forKey: "slideMove"), move.duration > 0 else { return nil }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        return (now - move.beginTime) / move.duration
    }

    /// The pad is fading in or out right now ("Reduce motion").
    var padIsFading: Bool { padContainer.layer?.animation(forKey: "fade") != nil }

    /// Where the pad is drawn right now, in the middle of a move: how much of it
    /// is out of the screen edge, and its opacity (fix K1).
    var padOnScreen: (reach: CGFloat, opacity: Float) {
        guard let layout, let layer = padContainer.layer else { return (0, 0) }
        let shown = layer.presentation() ?? layer
        let window = padWindowFrame(layout)
        let size = CGFloat(tuning.padSize)
        let minX = shown.position.x - shown.anchorPoint.x * size
        let reach = layout.edge.side == .right ? window.width - minX : minX + size
        return (min(max(reach, 0), size), shown.opacity)
    }

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
