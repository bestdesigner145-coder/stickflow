// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
import StickflowCore

/// Typed access to `Localizable.xcstrings`. Keys are maintained by hand.
enum L10n {
    static var menuNewSticker: String { String(localized: "menu.new_sticker") }
    static var menuToggleAll: String { String(localized: "menu.toggle_all") }
    static var menuHiddenWhileSharing: String { String(localized: "menu.hidden_while_sharing") }
    static var menuPeelAll: String { String(localized: "menu.peel_all") }
    static var menuRestoreLast: String { String(localized: "menu.restore_last") }
    static var menuHistory: String { String(localized: "menu.history") }
    static var menuStickerDisplay: String { String(localized: "menu.sticker_display") }
    static var menuDisplayAutomatic: String { String(localized: "menu.display_automatic") }
    static var menuSettings: String { String(localized: "menu.settings") }
    static var menuCheckUpdates: String { String(localized: "menu.check_updates") }
    static var menuLaunchAtLogin: String { String(localized: "menu.launch_at_login") }
    static var menuQuit: String { String(localized: "menu.quit") }

    static var stickerMenuPaperColor: String { String(localized: "sticker.menu.paper_color") }
    static var stickerMenuPeel: String { String(localized: "sticker.menu.peel") }
    static var stickerStripMenu: String { String(localized: "sticker.strip.menu") }
    static var stickerPlaceholder: String { String(localized: "sticker.placeholder") }

    static var padLabel: String { String(localized: "pad.label") }
    static var draftTitle: String { String(localized: "draft.title") }
    static var draftPlaceholder: String { String(localized: "draft.placeholder") }
    static var draftStick: String { String(localized: "draft.stick") }
    static var draftDictate: String { String(localized: "draft.dictate") }
    static var draftStopDictation: String { String(localized: "draft.dictate.stop") }
    static var draftStructuring: String { String(localized: "draft.structuring") }
    static var draftStop: String { String(localized: "draft.stop") }
    static var draftFailed: String { String(localized: "draft.failed") }
    static var draftStickAsIs: String { String(localized: "draft.failed.stick") }
    static var draftRetry: String { String(localized: "draft.failed.retry") }
    static var draftModeNew: String { String(localized: "draft.mode.new") }
    static var draftModeAppend: String { String(localized: "draft.mode.append") }

    static var dictationListening: String { String(localized: "dictation.listening") }
    static var dictationNoMicrophone: String { String(localized: "dictation.error.microphone") }
    static var dictationNoRecognition: String { String(localized: "dictation.error.recognition") }
    static var dictationNoOnDeviceModel: String { String(localized: "dictation.error.no_on_device") }
    static var dictationNothingHeard: String { String(localized: "dictation.error.nothing_heard") }
    static var dictationFailed: String { String(localized: "dictation.error.failed") }

    static func dictationModelDownloading(percent: Int) -> String {
        String.localizedStringWithFormat(String(localized: "dictation.model_downloading"), percent)
    }

    static var toastPeeledOne: String { String(localized: "toast.peeled_one") }
    static var toastRestore: String { String(localized: "toast.restore") }

    static var errorDatabaseTitle: String { String(localized: "error.database.title") }
    static var errorLoginItemTitle: String { String(localized: "error.login_item.title") }
    static var errorSaveTitle: String { String(localized: "error.save.title") }

    /// "4 more" under a sticker whose text does not fit.
    static func stickerMore(_ count: Int) -> String {
        String.localizedStringWithFormat(String(localized: "sticker.more"), count)
    }

    /// "Stickers peeled off: 5" in the toast after "Peel Off All Stickers".
    static func toastPeeledMany(_ count: Int) -> String {
        String.localizedStringWithFormat(String(localized: "toast.peeled_many"), count)
    }

    /// "⌥ — edit" hint next to the cursor.
    static func hintEditKey(_ symbol: String) -> String {
        String.localizedStringWithFormat(String(localized: "hint.edit_key"), symbol)
    }

    static func name(of color: PaperColor) -> String {
        switch color {
        case .yellow: String(localized: "color.yellow")
        case .blue: String(localized: "color.blue")
        case .green: String(localized: "color.green")
        case .pink: String(localized: "color.pink")
        case .paper: String(localized: "color.paper")
        }
    }
}
