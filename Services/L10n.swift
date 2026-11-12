// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
import StickflowCore

/// Typed access to `Localizable.xcstrings`. Keys are maintained by hand.
enum L10n {
    static var menuNewSticker: String { String(localized: "menu.new_sticker") }
    static var menuToggleAll: String { String(localized: "menu.toggle_all") }
    static var menuHistory: String { String(localized: "menu.history") }
    static var menuStickerDisplay: String { String(localized: "menu.sticker_display") }
    static var menuDisplayAutomatic: String { String(localized: "menu.display_automatic") }
    static var menuSettings: String { String(localized: "menu.settings") }
    static var menuCheckUpdates: String { String(localized: "menu.check_updates") }
    static var menuLaunchAtLogin: String { String(localized: "menu.launch_at_login") }
    static var menuQuit: String { String(localized: "menu.quit") }

    static var stickerMenuPaperColor: String { String(localized: "sticker.menu.paper_color") }
    static var stickerMenuPeel: String { String(localized: "sticker.menu.peel") }
    static var stickerMenuDelete: String { String(localized: "sticker.menu.delete") }
    static var stickerPlaceholder: String { String(localized: "sticker.placeholder") }

    static var errorDatabaseTitle: String { String(localized: "error.database.title") }
    static var errorLoginItemTitle: String { String(localized: "error.login_item.title") }
    static var errorSaveTitle: String { String(localized: "error.save.title") }

    /// "4 more" under a sticker whose text does not fit.
    static func stickerMore(_ count: Int) -> String {
        String.localizedStringWithFormat(String(localized: "sticker.more"), count)
    }

    /// "⌥ — edit" hint next to the cursor.
    static func hintEditKey(_ symbol: String) -> String {
        String.localizedStringWithFormat(String(localized: "hint.edit_key"), symbol)
    }

    static func name(of color: PaperColor) -> String {
        switch color {
        case .paper: String(localized: "color.paper")
        case .cream: String(localized: "color.cream")
        case .sage: String(localized: "color.sage")
        }
    }
}
