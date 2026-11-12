// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

/// Owns every sticker on screen: creation, placement, persistence and pointer routing.
@MainActor
final class StickerManager: NSObject {
    /// Called with a localized title when storage fails.
    var onError: ((String, Error) -> Void)?

    private let tuning: Tuning
    private let preferences: Preferences
    private let repository: StickerRepository
    private let displays: DisplayService
    private let pointer = PointerTracker()
    private let hint = EditHintController()

    private(set) var controllers: [StickerController] = []
    private(set) var areStickersHidden = false
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
        if areStickersHidden {
            setStickersHidden(false)
        }
        let now = Date()
        let sticker = Sticker(color: preferences.defaultColor, source: .typed, createdAt: now, stuckAt: now)
        let controller = addController(for: sticker)
        place(controller)
        controller.show()
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

    /// Takes the sticker off the screen (spec 4.10): done if every task is ticked,
    /// otherwise a draft. The peel gesture and its animation come in stage 2.
    func peel(_ controller: StickerController) {
        controller.endEditing()
        guard !controller.isClosed else { return } // it was empty and got discarded
        let now = Date()
        controller.updateSticker { sticker in
            sticker.status = sticker.statusAfterPeeling
            sticker.peeledAt = now
            sticker.updatedAt = now
        }
        persist(controller)
        remove(controller)
    }

    func delete(_ controller: StickerController) {
        controller.endEditing()
        guard !controller.isClosed else { return }
        let now = Date()
        controller.updateSticker { sticker in
            sticker.status = .trashed
            sticker.deletedAt = now
            sticker.updatedAt = now
        }
        persist(controller)
        remove(controller)
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
        areStickersHidden = hidden
        hint.hide()
        for controller in controllers {
            if hidden {
                controller.hide()
            } else {
                controller.show()
            }
        }
        pointer.kick()
    }

    func toggleStickersHidden() {
        setStickersHidden(!areStickersHidden)
    }

    // MARK: Settings

    /// Call after `Tuning` or `Preferences` changed.
    func applyPreferences() {
        for controller in controllers {
            controller.applySettings()
            place(controller)
        }
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
        guard !areStickersHidden else { return }
        for controller in controllers {
            controller.pointerDidUpdate(sample)
        }
    }

    private func needsPolling(at location: CGPoint) -> Bool {
        guard !areStickersHidden else { return false }
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
            hideFromScreenSharing: preferences.hideFromScreenSharing
        )
    }

    func hideHint() {
        hint.hide()
    }
}
