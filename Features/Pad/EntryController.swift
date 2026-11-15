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

    init(tuning: Tuning, preferences: Preferences, displays: any ScreenGeometry, stickers: StickerManager) {
        self.tuning = tuning
        self.preferences = preferences
        self.displays = displays
        self.stickers = stickers
        draft = DraftController(tuning: tuning, preferences: preferences)
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

        draft.onStick = { [weak self] text in
            self?.stickDraft(text)
        }
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

    private func stickDraft(_ text: String) {
        // Structuring arrives in stage 3; until then Return sticks the text as it is.
        let plan = PlainTextPlan.make(from: text, plainLineKind: tuning.newLineAfterTitleIsTodo ? .todo : .text)
        let draftFrame = draft.frameOnScreen
        draft.close(animated: true)
        stickers.stick(plan, rawInput: text, flyingFrom: draftFrame)
        stickers.pointerNeedsAttention()
    }

    private func cancelDraft(_ text: String) {
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
