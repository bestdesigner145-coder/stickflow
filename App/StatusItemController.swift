// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import KeyboardShortcuts

/// The menu bar item and its menu (spec 5.4).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private unowned let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = Self.makeIcon()
        statusItem.button?.setAccessibilityLabel("Stickflow")
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu()
        environment.models.observe { [weak self] in self?.showProgress() }
        showProgress()
    }

    /// The download of the models is seen in the menu bar too (spec 18.10 A3).
    private func showProgress() {
        guard let button = statusItem.button else { return }
        if case let .downloading(received, total) = environment.models.state, total > 0 {
            statusItem.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            button.title = " \(Int(Double(received) / Double(total) * 100))%"
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            statusItem.length = NSStatusItem.squareLength
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    /// While the menu is open its item reacts to the hotkey itself. The global
    /// hotkey would fire a second time when the menu closes and undo the action.
    func menuWillOpen(_ menu: NSMenu) {
        KeyboardShortcuts.disable(.toggleStickers)
    }

    func menuDidClose(_ menu: NSMenu) {
        KeyboardShortcuts.enable(.toggleStickers)
    }

    // MARK: Menu

    private func rebuildMenu() {
        menu.removeAllItems()

        // The key equivalent is shown for reference; the real hotkey is global.
        let newItem = makeItem(L10n.menuNewSticker, action: #selector(newSticker), key: "\r")
        newItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(newItem)
        switch environment.models.state {
        case let .downloading(received, total):
            let percent = total > 0 ? Int(Double(received) / Double(total) * 100) : 0
            menu.addItem(makeItem(L10n.menuModelsDownloading(percent: percent), action: #selector(showModelSetup)))
        case .missing, .failed:
            menu.addItem(makeItem(L10n.menuModels, action: #selector(showModelSetup)))
        case .ready:
            break
        }
        if environment.stickers.areStickersHiddenByCapture {
            menu.addItem(makeItem(L10n.menuHiddenWhileSharing, action: nil, enabled: false))
            menu.addItem(.separator())
        }
        // The quick way to get stickers out of sight, e.g. before sharing the screen.
        // Shows the hotkey once the user has assigned one.
        let toggleItem = makeItem(L10n.menuToggleAll, action: #selector(toggleStickers))
        toggleItem.setShortcut(for: .toggleStickers)
        menu.addItem(toggleItem)
        menu.addItem(makeItem(
            L10n.menuPeelAll,
            action: #selector(peelAllStickers),
            enabled: !environment.stickers.controllers.isEmpty
        ))
        // The way back until history arrives in stage 2.
        menu.addItem(makeItem(
            L10n.menuRestoreLast,
            action: #selector(restoreLastPeeled),
            enabled: environment.stickers.canRestoreLastPeeled
        ))
        menu.addItem(makeItem(L10n.menuHistory, action: nil, enabled: false))

        menu.addItem(.separator())

        let displayItem = makeItem(L10n.menuStickerDisplay, action: nil)
        displayItem.submenu = makeDisplayMenu()
        menu.addItem(displayItem)

        let loginMenuItem = makeItem(L10n.menuLaunchAtLogin, action: #selector(toggleLaunchAtLogin))
        loginMenuItem.state = environment.loginItem.isEnabled ? .on : .off
        menu.addItem(loginMenuItem)

        // Sorting is set here (spec 18.10 C1); the rest of the settings and the updater arrive in stage 4.
        menu.addItem(makeItem(L10n.menuSettings, action: #selector(showSettings), key: ","))
        menu.addItem(makeItem(L10n.menuCheckUpdates, action: nil, enabled: false))

        #if DEBUG
        menu.addItem(.separator())
        menu.addItem(makeItem("Tuning…", action: #selector(showTuningPanel)))
        // Which build this is: the quickest answer to "am I running the new one?".
        menu.addItem(makeItem(L10n.menuBuild(BuildStamp.text), action: nil, enabled: false))
        #endif

        menu.addItem(.separator())
        menu.addItem(makeItem(L10n.menuQuit, action: #selector(quit), key: "q"))
    }

    private func makeDisplayMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let selected = environment.preferences.stickerDisplayUUID

        let automatic = makeItem(L10n.menuDisplayAutomatic, action: #selector(pickDisplay(_:)))
        automatic.state = selected == nil ? .on : .off
        submenu.addItem(automatic)
        submenu.addItem(.separator())

        for screen in environment.displays.screens {
            guard let uuid = screen.uuid else { continue }
            let item = makeItem(screen.name, action: #selector(pickDisplay(_:)))
            item.representedObject = uuid
            item.state = selected == uuid ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    private func makeItem(_ title: String, action: Selector?, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == nil ? nil : self
        item.isEnabled = enabled
        return item
    }

    // MARK: Actions

    @objc private func newSticker() {
        environment.entry.toggleDraft()
    }

    @objc private func toggleStickers() {
        environment.stickers.toggleStickersHidden()
    }

    @objc private func peelAllStickers() {
        environment.stickers.peelAll()
    }

    @objc private func restoreLastPeeled() {
        environment.stickers.restoreLastPeeled()
    }

    @objc private func pickDisplay(_ sender: NSMenuItem) {
        environment.stickers.setStickerDisplay(uuid: sender.representedObject as? String)
        environment.entry.applySettings()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = environment.loginItem
        do {
            try service.setEnabled(!service.isEnabled)
        } catch {
            AppEnvironment.presentAlert(title: L10n.errorLoginItemTitle, error: error)
        }
    }

    @objc private func showSettings() {
        environment.showSettings()
    }

    @objc private func showModelSetup() {
        environment.showModelSetup()
    }

    #if DEBUG
    @objc private func showTuningPanel() {
        environment.showTuningPanel()
    }
    #endif

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Icon

    /// A hand-drawn-ish sticker with a folded corner, as a template image.
    /// The final icon is the author's; this is a stand-in (spec 6.6).
    private static func makeIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let paper = rect.insetBy(dx: 3, dy: 3)
            let fold: CGFloat = 4.5

            let outline = NSBezierPath()
            outline.move(to: NSPoint(x: paper.minX, y: paper.maxY))
            outline.line(to: NSPoint(x: paper.maxX, y: paper.maxY))
            outline.line(to: NSPoint(x: paper.maxX, y: paper.minY + fold))
            outline.line(to: NSPoint(x: paper.maxX - fold, y: paper.minY))
            outline.line(to: NSPoint(x: paper.minX, y: paper.minY))
            outline.close()
            outline.lineWidth = 1.4
            outline.lineJoinStyle = .round

            let corner = NSBezierPath()
            corner.move(to: NSPoint(x: paper.maxX, y: paper.minY + fold))
            corner.line(to: NSPoint(x: paper.maxX - fold, y: paper.minY + fold))
            corner.line(to: NSPoint(x: paper.maxX - fold, y: paper.minY))
            corner.lineWidth = 1.2
            corner.lineJoinStyle = .round

            NSColor.black.setStroke()
            outline.stroke()
            corner.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
