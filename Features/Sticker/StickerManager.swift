// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

/// Owns every sticker on screen: creation, placement, persistence and pointer routing.
@MainActor
final class StickerManager: NSObject {
    /// Called with a localized title when storage fails.
    var onError: ((String, Error) -> Void)?
    /// Asks for the temporary ⌘Z ("bring the peeled sticker back") to be registered
    /// or released. See `HotkeyService.setUndoPeelArmed`.
    var onUndoShortcutArmedChange: ((Bool) -> Void)?

    private let tuning: Tuning
    private let preferences: Preferences
    private let repository: StickerRepository
    private let displays: DisplayService
    private let pointer = PointerTracker()
    private let hint = EditHintController()
    private let toast = ToastController()
    private lazy var focusReturn = FocusReturnPanel.make()
    let captureWatcher = ScreenCaptureWatcher()

    private(set) var controllers: [StickerController] = []
    /// Hidden by the user: menu bar item or hotkey.
    private(set) var areStickersHidden = false
    /// Hidden because something is recording or sharing the screen (experimental).
    private(set) var areStickersHiddenByCapture = false
    private var isAnythingHidden: Bool { areStickersHidden || areStickersHiddenByCapture }

    /// A sticker that was just taken off the screen.
    private struct PeeledSticker {
        let id: UUID
        let paperFrame: CGRect
    }

    /// Where peeled stickers were, so that bringing one back puts it exactly there
    /// even if it had no position of its own. Lives until the app quits.
    private var peeledFrames: [UUID: CGRect] = [:]
    private var undoClickMonitors: [Any] = []
    /// How many times the helper window failed to take the focus and the sticker
    /// had to be hidden and shown instead. Stays at zero when all is well.
    private(set) var focusReturnFallbacks = 0
    /// Stickers with unsaved text changes; flushed shortly after typing stops.
    private var unsaved: Set<UUID> = []
    /// Stickers that exist in the database, so a discarded one is removed there too.
    private var stored: Set<UUID> = []

    init(tuning: Tuning, preferences: Preferences, repository: StickerRepository, displays: DisplayService) {
        self.tuning = tuning
        self.preferences = preferences
        self.repository = repository
        self.displays = displays
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        do {
            for sticker in try repository.stickers(status: .active) {
                stored.insert(sticker.id)
                let controller = addController(for: sticker)
                place(controller)
                controller.show()
            }
        } catch {
            onError?(L10n.errorDatabaseTitle, error)
        }

        pointer.pollInterval = { [tuning] in tuning.pointerPollInterval }
        pointer.onSample = { [weak self] sample in
            self?.dispatch(sample)
        }
        pointer.needsPolling = { [weak self] location in
            self?.needsPolling(at: location) ?? false
        }
        pointer.start()

        toast.onDismiss = { [weak self] in
            self?.setUndoShortcutArmed(false)
        }
        captureWatcher.onChange = { [weak self] isCaptured in
            self?.setHiddenByCapture(isCaptured)
        }
        updateCaptureWatching()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    /// Commits anything in flight. Called before the app quits.
    func flush() {
        for controller in controllers {
            controller.endEditing()
        }
        flushUnsaved()
        setUndoShortcutArmed(false)
    }

    // MARK: Creating and removing

    /// The quick-input action. Until the composer arrives in stage 2 it sticks an
    /// empty sticker at the default spot and starts editing it. Pressing the
    /// hotkey again on a still-empty sticker closes it (spec 5.4).
    func createSticker() {
        if let blank = controllers.first(where: { $0.mode == .editing && $0.sticker.isBlank }) {
            blank.endEditing()
            return
        }
        // Asking for a new sticker is asking to see stickers.
        showAll()
        let now = Date()
        let sticker = Sticker(color: preferences.defaultColor, source: .typed, createdAt: now, stuckAt: now)
        let controller = addController(for: sticker)
        place(controller)
        controller.show(animated: true)
        controller.beginEditing(at: nil)
    }

    @discardableResult
    private func addController(for sticker: Sticker) -> StickerController {
        let controller = StickerController(sticker: sticker, tuning: tuning, preferences: preferences)
        controller.manager = self
        controllers.append(controller)
        return controller
    }

    private func remove(_ controller: StickerController) {
        unsaved.remove(controller.sticker.id)
        controllers.removeAll { $0 === controller }
        controller.close()
    }

    // MARK: Peeling off and bringing back (spec 4.10)

    /// Takes the sticker off the screen: done if every task is ticked, otherwise a
    /// draft. It stays in the database with the time it was peeled, and the toast
    /// offers to bring it back. The corner-peel gesture comes in stage 2.
    func peel(_ controller: StickerController) {
        guard let peeled = takeOff(controller) else { return }
        announce([peeled])
    }

    /// Menu bar: "Peel Off All Stickers". One toast brings all of them back.
    func peelAll() {
        let everything = controllers
        let peeled = everything.compactMap { takeOff($0) }
        guard !peeled.isEmpty else { return }
        announce(peeled)
    }

    private func takeOff(_ controller: StickerController) -> PeeledSticker? {
        controller.endEditing()
        guard !controller.isClosed else { return nil } // it was empty and got discarded
        let frame = controller.paperFrame
        let wasOnScreen = controller.isOnScreen
        let now = Date()
        controller.updateSticker { sticker in
            sticker.status = sticker.statusAfterPeeling
            sticker.peeledAt = now
            sticker.updatedAt = now
        }
        persist(controller)

        let id = controller.sticker.id
        unsaved.remove(id)
        controllers.removeAll { $0 === controller }
        peeledFrames[id] = frame
        // It flies to the right edge of its screen, where the pad will live (stage 2).
        let edge = wasOnScreen ? displays.screen(containing: frame)?.frame.maxX : nil
        controller.peelAway(towardsX: edge)
        return PeeledSticker(id: id, paperFrame: frame)
    }

    private func announce(_ peeled: [PeeledSticker]) {
        pointer.kick()
        guard let first = peeled.first,
              let screen = displays.screen(containing: first.paperFrame)
              ?? displays.stickerScreen(preferredUUID: preferences.stickerDisplayUUID)
        else { return }
        let message = peeled.count == 1 ? L10n.toastPeeledOne : L10n.toastPeeledMany(peeled.count)
        toast.show(message: message, actionTitle: L10n.toastRestore, on: screen, tuning: tuning) { [weak self] in
            self?.restore(peeled)
        }
        setUndoShortcutArmed(tuning.undoPeelUsesCommandZ)
    }

    /// The toast's "Restore" button, or ⌘Z while the toast is up.
    func undoLastPeel() {
        toast.performAction()
    }

    /// True while the "Sticker peeled off · Restore" toast is on screen.
    var isUndoToastVisible: Bool { toast.isVisible }

    #if DEBUG
    /// For the self-check's snapshots.
    var toastSnapshotView: NSView? { toast.snapshotView }
    #endif

    private func restore(_ peeled: [PeeledSticker]) {
        for item in peeled {
            do {
                if let sticker = try repository.sticker(id: item.id) {
                    putBack(sticker)
                }
            } catch {
                onError?(L10n.errorDatabaseTitle, error)
            }
        }
    }

    /// Menu bar: "Restore Last Peeled Sticker". The way back until history exists (stage 2).
    func restoreLastPeeled() {
        do {
            guard let sticker = try repository.lastPeeled() else { return }
            toast.hide()
            putBack(sticker)
        } catch {
            onError?(L10n.errorDatabaseTitle, error)
        }
    }

    var canRestoreLastPeeled: Bool {
        (try? repository.lastPeeled()) != nil
    }

    private func putBack(_ stored: Sticker) {
        guard stored.status != .active, stored.deletedAt == nil,
              !controllers.contains(where: { $0.sticker.id == stored.id })
        else { return }
        var sticker = stored
        let now = Date()
        sticker.status = .active
        sticker.peeledAt = nil
        sticker.stuckAt = now
        sticker.updatedAt = now
        save(sticker)

        showAll()
        let controller = addController(for: sticker)
        place(controller)
        // The same place it was peeled from (spec 4.11), even if it had been
        // sitting at the default spot.
        if let frame = peeledFrames.removeValue(forKey: sticker.id),
           let screen = displays.screen(containing: frame) {
            let size = controller.paperFrame.size
            let paper = CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
            controller.setPaperFrame(StickerGeometry.clamped(paper, within: screen.visibleFrame))
        }
        controller.show(animated: true)
        pointer.kick()
    }

    /// ⌘Z belongs to the app in front. It is borrowed only between peeling and the
    /// user's next click (or the toast's timeout), so that "peel, ⌘Z" works and
    /// Undo in other apps is back the moment the user turns to them.
    private func setUndoShortcutArmed(_ armed: Bool) {
        for monitor in undoClickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        undoClickMonitors.removeAll()
        onUndoShortcutArmedChange?(armed)
        guard armed else { return }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setUndoShortcutArmed(false)
            }
        }
        if let global { undoClickMonitors.append(global) }

        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setUndoShortcutArmed(false)
            }
            return event
        }
        if let local { undoClickMonitors.append(local) }
    }

    // MARK: Keyboard focus

    /// Gives the keyboard back to the app the user was working in, after editing.
    func returnKeyboardFocus(from controller: StickerController) {
        if tuning.focusReturnUsesHelperPanel {
            // The sticker stays on screen; an invisible helper window takes the
            // focus from it and leaves.
            focusReturn.releaseFocus(near: controller.paperFrame)
            guard controller.panel.isKeyWindow else { return }
            // The helper did not get the focus. Typing must never stay stuck in a
            // sticker, so use the way that always works.
            focusReturnFallbacks += 1
        }
        // The first implementation: works, but the sticker blinks.
        controller.panel.orderOut(nil)
        controller.panel.orderFrontRegardless()
    }

    /// Drops a sticker that ended up without any text.
    func discard(_ controller: StickerController) {
        if stored.contains(controller.sticker.id) {
            let now = Date()
            controller.updateSticker { sticker in
                sticker.status = .trashed
                sticker.deletedAt = now
                sticker.updatedAt = now
            }
            save(controller.sticker)
        }
        remove(controller)
    }

    // MARK: Visibility

    func setStickersHidden(_ hidden: Bool) {
        guard hidden != areStickersHidden else { return }
        areStickersHidden = hidden
        applyVisibility()
    }

    /// Menu bar item and hotkey: the quick way to get every sticker out of sight,
    /// for example before sharing the screen.
    func toggleStickersHidden() {
        if isAnythingHidden {
            showAll()
        } else {
            setStickersHidden(true)
        }
    }

    /// Shows the stickers whatever hid them. A capture that is still running does
    /// not hide them again: the user's explicit action wins until it restarts.
    private func showAll() {
        guard isAnythingHidden else { return }
        areStickersHidden = false
        areStickersHiddenByCapture = false
        applyVisibility()
    }

    private func setHiddenByCapture(_ hidden: Bool) {
        guard hidden != areStickersHiddenByCapture else { return }
        areStickersHiddenByCapture = hidden
        applyVisibility()
    }

    private func applyVisibility() {
        let hidden = isAnythingHidden
        hint.hide()
        if hidden {
            toast.hide(animated: false)
        }
        for controller in controllers {
            if hidden {
                controller.hide() // at once: hiding is the urgent direction
            } else {
                controller.show(animated: true)
            }
        }
        pointer.kick()
    }

    /// Experimental (see `ScreenCaptureWatcher`): hide stickers while the screen is captured.
    private func updateCaptureWatching() {
        if preferences.hideWhileScreenIsCaptured {
            captureWatcher.start()
        } else {
            captureWatcher.stop()
        }
    }

    // MARK: Settings

    /// Call after `Tuning` or `Preferences` changed.
    func applyPreferences() {
        for controller in controllers {
            controller.applySettings()
            place(controller)
        }
        updateCaptureWatching()
        pointer.kick()
    }

    func changeFontSize(by delta: Int) {
        preferences.fontSize += Double(delta)
        preferences.persist()
        applyPreferences()
    }

    /// Moves all stickers to another display. `nil` means the one with the menu bar.
    func setStickerDisplay(uuid: String?) {
        preferences.stickerDisplayUUID = uuid
        preferences.persist()
        for controller in controllers {
            controller.updateSticker { sticker in
                sticker.placement?.displayKey = nil
            }
            place(controller)
            persist(controller)
        }
    }

    // MARK: Placement

    private func targetScreen(for sticker: Sticker) -> NSScreen? {
        if let key = sticker.placement?.displayKey,
           let uuid = DisplayKey.uuid(from: key),
           let screen = displays.screen(forUUID: uuid) {
            return screen
        }
        // The sticker's own display is gone: fall back, and return when it is plugged back in.
        return displays.stickerScreen(preferredUUID: preferences.stickerDisplayUUID)
    }

    /// Puts the sticker where it belongs on its display: the remembered position
    /// for this display and resolution, or the default anchor.
    func place(_ controller: StickerController) {
        guard !controller.isClosed, let screen = targetScreen(for: controller.sticker) else { return }
        controller.resizeToFit()

        let size = controller.paperFrame.size
        let topLeft: CGPoint
        if let stored = controller.sticker.placement?.positions[displays.key(for: screen)] {
            topLeft = CGPoint(x: screen.frame.minX + stored.x, y: screen.frame.maxY - stored.y)
        } else {
            topLeft = defaultTopLeft(for: controller, width: size.width, on: screen)
        }

        let paper = CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        controller.setPaperFrame(StickerGeometry.clamped(paper, within: screen.visibleFrame))
    }

    /// Default anchor (spec 4.5): upper right of the work area, below window toolbars.
    /// Until stacks arrive in stage 2, stickers that would land on the same spot are cascaded.
    private func defaultTopLeft(for controller: StickerController, width: CGFloat, on screen: NSScreen) -> CGPoint {
        let topRight = StickerGeometry.defaultTopRight(
            visibleFrame: screen.visibleFrame,
            insetRight: CGFloat(tuning.anchorInsetRight),
            insetTop: CGFloat(tuning.anchorInsetTop)
        )
        let offset = CGFloat(tuning.cascadeOffset)
        var step = 0
        var candidate = topRight
        while step < 12 {
            let isTaken = controllers.contains { other in
                guard other !== controller, other.isOnScreen else { return false }
                let frame = other.paperFrame
                return abs(frame.maxX - candidate.x) < 2 && abs(frame.maxY - candidate.y) < 2
            }
            if !isTaken { break }
            step += 1
            candidate = CGPoint(x: topRight.x - CGFloat(step) * offset, y: topRight.y - CGFloat(step) * offset)
        }
        return CGPoint(x: candidate.x - width, y: candidate.y)
    }

    /// Double click on the glue strip: forget the custom position on the sticker display.
    func moveToDefaultAnchor(_ controller: StickerController) {
        guard let screen = displays.stickerScreen(preferredUUID: preferences.stickerDisplayUUID) else { return }
        let key = displays.key(for: screen)
        controller.updateSticker { sticker in
            sticker.placement?.displayKey = nil
            sticker.placement?.positions[key] = nil
        }
        place(controller)
        persist(controller)
    }

    /// The user dropped the sticker: snap it and remember the spot for this display.
    func stickerDidMove(_ controller: StickerController) {
        let dropped = controller.paperFrame
        guard let screen = displays.screen(containing: dropped) ?? targetScreen(for: controller.sticker) else { return }

        let others = controllers
            .filter { $0 !== controller && $0.isOnScreen }
            .map { $0.paperFrame }
        let snapped = StickerGeometry.snapped(
            dropped,
            within: screen.visibleFrame,
            others: others,
            distance: CGFloat(tuning.magnetDistance)
        )
        controller.setPaperFrame(snapped)

        let key = displays.key(for: screen)
        let position = StickerPoint(
            x: Double(snapped.minX - screen.frame.minX),
            y: Double(screen.frame.maxY - snapped.maxY)
        )
        controller.updateSticker { sticker in
            var placement = sticker.placement ?? Placement()
            placement.displayKey = key
            placement.positions[key] = position
            sticker.placement = placement
        }
        persist(controller)
    }

    @objc private func screensDidChange(_ notification: Notification) {
        for controller in controllers {
            place(controller)
        }
        pointer.kick()
    }

    @objc private func displayOptionsDidChange(_ notification: Notification) {
        // "Reduce transparency" and friends changed.
        for controller in controllers {
            controller.applySettings()
        }
    }

    // MARK: Editing coordination

    /// Only one sticker is edited at a time.
    func willBeginEditing(_ controller: StickerController) {
        for other in controllers where other !== controller {
            other.endEditing()
        }
    }

    // MARK: Persistence

    func persist(_ controller: StickerController) {
        unsaved.remove(controller.sticker.id)
        // A sticker without text is never written; it disappears when editing ends.
        guard !controller.sticker.isBlank || stored.contains(controller.sticker.id) else { return }
        save(controller.sticker)
    }

    /// Saves after a short pause so that typing does not hit the disk on every key press.
    func schedulePersist(_ controller: StickerController) {
        unsaved.insert(controller.sticker.id)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(flushUnsaved), object: nil)
        perform(#selector(flushUnsaved), with: nil, afterDelay: 0.4)
    }

    @objc private func flushUnsaved() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(flushUnsaved), object: nil)
        for controller in controllers where unsaved.contains(controller.sticker.id) {
            persist(controller)
        }
        unsaved.removeAll()
    }

    private func save(_ sticker: Sticker) {
        do {
            try repository.save(sticker)
            stored.insert(sticker.id)
        } catch {
            onError?(L10n.errorSaveTitle, error)
        }
    }

    // MARK: Pointer and hint

    private func dispatch(_ sample: PointerSample) {
        guard !isAnythingHidden else { return }
        for controller in controllers {
            controller.pointerDidUpdate(sample)
        }
    }

    private func needsPolling(at location: CGPoint) -> Bool {
        guard !isAnythingHidden else { return false }
        return controllers.contains { $0.wantsPointerUpdates(at: location) }
    }

    /// Something changed under a possibly still cursor; re-check right away.
    func pointerNeedsAttention() {
        pointer.kick()
    }

    func showEditHintIfNeeded(near location: CGPoint) {
        guard preferences.editHintShownCount < tuning.hintMaxShows else { return }
        preferences.editHintShownCount += 1
        preferences.persist()
        hint.show(
            text: L10n.hintEditKey(preferences.editKey.symbol),
            near: location,
            duration: tuning.hintDuration,
            hideFromScreenCapture: preferences.hideFromScreenCapture
        )
    }

    func hideHint() {
        hint.hide()
    }
}
