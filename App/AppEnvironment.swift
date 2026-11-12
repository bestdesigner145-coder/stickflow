// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

/// The dependency container: the only place where services are created and
/// wired together (spec 10.1). Everything else receives what it needs.
@MainActor
final class AppEnvironment {
    let tuning = Tuning()
    let preferences = Preferences()
    let displays = DisplayService()
    let loginItem = LoginItemService()
    let hotkeys = HotkeyService()
    let repository: StickerRepository
    let stickers: StickerManager

    private var statusItem: StatusItemController?
    private var reportedErrors: Set<String> = []
    #if DEBUG
    private var tuningPanel: TuningPanelController?
    #endif

    init() throws {
        let database = try AppDatabase.onDisk(at: AppDatabase.defaultURL())
        repository = StickerRepository(database: database)
        stickers = StickerManager(
            tuning: tuning,
            preferences: preferences,
            repository: repository,
            displays: displays
        )
    }

    func start() {
        stickers.onError = { [weak self] title, error in
            self?.report(title: title, error: error)
        }
        stickers.start()
        hotkeys.start { [weak self] in
            self?.stickers.createSticker()
        }
        statusItem = StatusItemController(environment: self)
    }

    // MARK: Debug panel

    #if DEBUG
    func showTuningPanel() {
        if tuningPanel == nil {
            tuningPanel = TuningPanelController(environment: self)
        }
        tuningPanel?.show()
    }
    #endif

    // MARK: Errors

    /// Shows each kind of error once per launch; repeating it on every key press helps nobody.
    func report(title: String, error: Error) {
        guard reportedErrors.insert(title).inserted else { return }
        Self.presentAlert(title: title, error: error)
    }

    static func presentAlert(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}
