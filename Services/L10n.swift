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
    static func menuBuild(_ stamp: String) -> String {
        String.localizedStringWithFormat(String(localized: "menu.build"), stamp)
    }

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

    static var dictationListening: String { String(localized: "dictation.listening") }
    static var dictationNoMicrophone: String { String(localized: "dictation.error.microphone") }
    static var dictationNothingHeard: String { String(localized: "dictation.error.nothing_heard") }
    static var dictationFailed: String { String(localized: "dictation.error.failed") }

    static func cloudConsentTitle(provider: String) -> String {
        String.localizedStringWithFormat(String(localized: "cloud.consent.title"), provider)
    }

    static var cloudConsentInfo: String { String(localized: "cloud.consent.info") }
    static var cloudConsentContinue: String { String(localized: "cloud.consent.continue") }
    static var cloudConsentCancel: String { String(localized: "cloud.consent.cancel") }
    static var cloudConsentRemember: String { String(localized: "cloud.consent.remember") }

    /// The models (spec 18.1, 18.10 A3).
    static func speechPreparing(percent: Int) -> String {
        String.localizedStringWithFormat(String(localized: "speech.preparing"), percent)
    }

    static var speechRetry: String { String(localized: "speech.retry") }
    static var speechUnsupported: String { String(localized: "speech.unsupported") }

    static var setupTitle: String { String(localized: "setup.title") }
    static func setupInfo(gigabytes: String) -> String {
        String.localizedStringWithFormat(String(localized: "setup.info"), gigabytes)
    }

    static var setupDownload: String { String(localized: "setup.download") }
    static var setupLater: String { String(localized: "setup.later") }
    static var setupHide: String { String(localized: "setup.hide") }
    static var setupClose: String { String(localized: "setup.close") }
    static var setupRetry: String { String(localized: "setup.retry") }
    static func setupProgress(received: String, total: String) -> String {
        String.localizedStringWithFormat(String(localized: "setup.progress"), received, total)
    }

    static var setupReady: String { String(localized: "setup.ready") }
    static var setupFailed: String { String(localized: "setup.failed") }
    static func menuModelsDownloading(percent: Int) -> String {
        String.localizedStringWithFormat(String(localized: "menu.models_downloading"), percent)
    }

    static var menuModels: String { String(localized: "menu.models") }

    /// Structuring without the model, and its failures (spec 18.10 A3, C2).
    static var toastStructureLater: String { String(localized: "toast.structure_later") }
    // Voice commands for a sticker (spec 18.22).
    static var voiceUnclearLine: String { String(localized: "voice.unclear_line") }
    static var voiceCommand: String { String(localized: "voice.command") }
    /// What a sticker says under it when a command could not be sent; `nil` — nothing to say.
    static func stickerEditFailure(_ error: StructurerError, provider: String) -> String? {
        switch error {
        case .missingKey: structureNoKey(provider)
        case .rejectedKey: structureBadKey(provider)
        case .noCredit: structureNoCredit(provider)
        case .noModel: structureNoModel(provider)
        default: nil
        }
    }

    static var toastStructureReady: String { String(localized: "toast.structure_ready") }
    static var toastStructure: String { String(localized: "toast.structure") }
    static var toastDownload: String { String(localized: "toast.download") }
    static func structureNoKey(_ provider: String) -> String {
        String.localizedStringWithFormat(String(localized: "structure.error.no_key"), provider)
    }

    static func structureBadKey(_ provider: String) -> String {
        String.localizedStringWithFormat(String(localized: "structure.error.bad_key"), provider)
    }

    static var structureOffline: String { String(localized: "structure.error.offline") }
    static func structureNoCredit(_ provider: String) -> String {
        String.localizedStringWithFormat(String(localized: "structure.error.no_credit"), provider)
    }

    static func structureUnavailable(_ provider: String) -> String {
        String.localizedStringWithFormat(String(localized: "structure.error.unavailable"), provider)
    }

    static func structureModelDownloading(percent: Int) -> String {
        String.localizedStringWithFormat(String(localized: "structure.error.model_downloading"), percent)
    }

    static func structureNoModel(_ provider: String) -> String {
        String.localizedStringWithFormat(String(localized: "structure.error.no_model"), provider)
    }

    static var structureTimedOut: String { String(localized: "structure.error.timed_out") }
    static var structureUseBuiltIn: String { String(localized: "structure.use_built_in") }

    // The settings window, "Sorting" (spec 18.10 C1).
    static var settingsTitle: String { String(localized: "settings.title") }
    static var providerLocal: String { String(localized: "provider.local") }
    static var providerCompatible: String { String(localized: "provider.compatible") }
    static var settingsProvider: String { String(localized: "settings.provider") }
    static var settingsLocalNote: String { String(localized: "settings.local_note") }
    static var settingsCloudNote: String { String(localized: "settings.cloud_note") }
    static var settingsModel: String { String(localized: "settings.model") }
    static var settingsSize: String { String(localized: "settings.size") }
    static var settingsGB: String { String(localized: "settings.gb") }
    static var settingsDelete: String { String(localized: "settings.delete") }
    static var settingsNotDownloaded: String { String(localized: "settings.not_downloaded") }
    static var settingsAddress: String { String(localized: "settings.address") }
    static var settingsHowToStart: String { String(localized: "settings.how_to_start") }
    static var settingsAskAgain: String { String(localized: "settings.ask_again") }
    static var settingsOllamaNotRunning: String { String(localized: "settings.ollama_not_running") }
    static var settingsOllamaNote: String { String(localized: "settings.ollama_note") }
    static func settingsKeySaved(_ end: String) -> String {
        String.localizedStringWithFormat(String(localized: "settings.key_saved"), end)
    }

    static var settingsNoKey: String { String(localized: "settings.no_key") }
    static var settingsKey: String { String(localized: "settings.key") }
    static var settingsNewKey: String { String(localized: "settings.new_key") }
    static var settingsSave: String { String(localized: "settings.save") }
    static var settingsCheck: String { String(localized: "settings.check") }
    static var settingsDeleteKey: String { String(localized: "settings.delete_key") }
    static var settingsKeyNote: String { String(localized: "settings.key_note") }
    static var settingsKeyWorks: String { String(localized: "settings.key_works") }
    static var settingsOffline: String { String(localized: "settings.offline") }
    static func settingsNoAnswer(_ provider: String) -> String {
        String.localizedStringWithFormat(String(localized: "settings.no_answer"), provider)
    }

    /// "## heading · - point · [] task" under the placeholder (spec 18.5).
    static func markupHint(heading: String, task: String) -> String {
        String.localizedStringWithFormat(String(localized: "hint.markup"), heading, task)
    }

    static var stickerDictate: String { String(localized: "sticker.dictate") }
    static var stickerStopDictation: String { String(localized: "sticker.dictate.stop") }

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
