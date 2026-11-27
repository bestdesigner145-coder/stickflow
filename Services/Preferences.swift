// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import Observation
import StickflowCore

/// Modifier key that turns a sticker into paper you can work with (spec 4.6).
enum EditKey: String, CaseIterable, Sendable {
    case option
    case control
    case command
    case function

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .option: .option
        case .control: .control
        case .command: .command
        case .function: .function
        }
    }

    var symbol: String {
        switch self {
        case .option: "⌥"
        case .control: "⌃"
        case .command: "⌘"
        case .function: "fn"
        }
    }
}

enum StickerSizeClass: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    var label: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        }
    }
}

/// User settings, persisted in `UserDefaults`.
///
/// Mutate a property, then call `persist()`. The settings window arrives in
/// stage 4; until then the debug panel edits these values.
@MainActor
@Observable
final class Preferences {
    static let fontSizeRange: ClosedRange<Double> = 12...17
    static let paperOpacityRange: ClosedRange<Double> = 0.5...1.0

    var paperOpacity: Double
    var fontSize: Double
    var sizeClass: StickerSizeClass
    var fadeEnabled: Bool
    var editKey: EditKey
    /// Asks the system to leave stickers out of screenshots (`sharingType = .none`).
    /// It does not stop apps that share the screen through ScreenCaptureKit, so it
    /// is off by default and promises nothing.
    var hideFromScreenCapture: Bool
    /// Take stickers off the screen while something records or shares it (spec 5.2).
    var hideDuringScreenSharing: Bool
    var showOverFullscreen: Bool
    /// Which screen edge the pad is called from (spec 4.1).
    var callEdge: CallEdge.Preference
    /// The thin strip of paper at the edge that hints where the pad is.
    var showsEdgeTab: Bool
    var smoothPadMotion: Bool
    var defaultColor: PaperColor
    /// UUID of the display stickers live on; `nil` means the display with the menu bar.
    var stickerDisplayUUID: String?
    /// How many times the "hold ⌥ to edit" hint has been shown.
    var editHintShownCount: Int

    // Structuring (spec 8.1). The window for these arrives with the settings (stage 4).
    var structurerChoice: StructurerChoice
    var ollamaHost: String
    var ollamaModel: String
    /// DeepSeek and other OpenAI-compatible services (spec 18.10 A4).
    var openAIBaseURL: String
    var openAIModel: String
    /// ChatGPT, through OpenAI's own API.
    var chatGPTModel: String
    /// The server at `ollamaHost` is LM Studio or another that speaks OpenAI's API.
    var localServerSpeaksOpenAI: Bool
    var claudeModel: String
    /// Providers the user allowed to receive text without being asked each time.
    var cloudConsent: [String]

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let paperOpacity = "paperOpacity"
        static let fontSize = "fontSize"
        static let sizeClass = "sizeClass"
        static let fadeEnabled = "fadeEnabled"
        static let editKey = "editKey"
        // "hideFromScreenSharing" was the first name of this setting, with the default
        // on. A new key makes the new default apply to everyone.
        static let hideFromScreenCapture = "hideFromScreenCapture"
        static let hideDuringScreenSharing = "hideDuringScreenSharing"
        static let showOverFullscreen = "showOverFullscreen"
        static let callEdge = "callEdge"
        static let showsEdgeTab = "showsEdgeTab"
        static let smoothPadMotion = "smoothPadMotion"
        static let defaultColor = "defaultColor"
        static let stickerDisplayUUID = "stickerDisplayUUID"
        static let editHintShownCount = "editHintShownCount"
        static let structurerChoice = "structurerChoice"
        static let ollamaHost = "ollamaHost"
        static let ollamaModel = "ollamaModel"
        static let openAIBaseURL = "openAIBaseURL"
        static let openAIModel = "openAIModel"
        static let claudeModel = "claudeModel"
        static let chatGPTModel = "chatGPTModel"
        static let localServerSpeaksOpenAI = "localServerSpeaksOpenAI"
        static let cloudConsent = "cloudConsent"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.paperOpacity: 0.72,
            Key.fontSize: 14.0,
            Key.sizeClass: StickerSizeClass.medium.rawValue,
            Key.fadeEnabled: true,
            Key.editKey: EditKey.option.rawValue,
            Key.hideFromScreenCapture: false,
            Key.hideDuringScreenSharing: true,
            Key.showOverFullscreen: false,
            Key.callEdge: CallEdge.Preference.automatic.rawValue,
            Key.showsEdgeTab: true,
            Key.smoothPadMotion: true,
            Key.defaultColor: PaperColor.default.rawValue,
            Key.editHintShownCount: 0,
            Key.structurerChoice: StructurerChoice.local.rawValue,
            Key.ollamaHost: "http://localhost:11434",
            Key.claudeModel: ChatProvider.claudeDefaultModel,
            Key.chatGPTModel: StructurerChoice.chatGPTDefaultModel,
            Key.openAIBaseURL: StructurerChoice.deepSeekBaseURL,
            Key.openAIModel: StructurerChoice.deepSeekModel,
        ])

        paperOpacity = Self.clamp(defaults.double(forKey: Key.paperOpacity), to: Self.paperOpacityRange)
        fontSize = Self.clamp(defaults.double(forKey: Key.fontSize).rounded(), to: Self.fontSizeRange)
        sizeClass = defaults.string(forKey: Key.sizeClass).flatMap(StickerSizeClass.init(rawValue:)) ?? .medium
        fadeEnabled = defaults.bool(forKey: Key.fadeEnabled)
        editKey = defaults.string(forKey: Key.editKey).flatMap(EditKey.init(rawValue:)) ?? .option
        hideFromScreenCapture = defaults.bool(forKey: Key.hideFromScreenCapture)
        hideDuringScreenSharing = defaults.bool(forKey: Key.hideDuringScreenSharing)
        showOverFullscreen = defaults.bool(forKey: Key.showOverFullscreen)
        callEdge = defaults.string(forKey: Key.callEdge).flatMap(CallEdge.Preference.init(rawValue:)) ?? .automatic
        showsEdgeTab = defaults.bool(forKey: Key.showsEdgeTab)
        smoothPadMotion = defaults.bool(forKey: Key.smoothPadMotion)
        defaultColor = defaults.string(forKey: Key.defaultColor).flatMap { PaperColor(stored: $0) } ?? .default
        stickerDisplayUUID = defaults.string(forKey: Key.stickerDisplayUUID)
        editHintShownCount = defaults.integer(forKey: Key.editHintShownCount)
        // The rules were a choice once; now they are only the fallback (spec 18.10 A4).
        structurerChoice = defaults.string(forKey: Key.structurerChoice).flatMap(StructurerChoice.init(rawValue:)) ?? .local
        ollamaHost = defaults.string(forKey: Key.ollamaHost) ?? ""
        ollamaModel = defaults.string(forKey: Key.ollamaModel) ?? ""
        openAIBaseURL = defaults.string(forKey: Key.openAIBaseURL) ?? ""
        openAIModel = defaults.string(forKey: Key.openAIModel) ?? ""
        claudeModel = defaults.string(forKey: Key.claudeModel) ?? ChatProvider.claudeDefaultModel
        chatGPTModel = defaults.string(forKey: Key.chatGPTModel) ?? StructurerChoice.chatGPTDefaultModel
        localServerSpeaksOpenAI = defaults.bool(forKey: Key.localServerSpeaksOpenAI)
        cloudConsent = defaults.stringArray(forKey: Key.cloudConsent) ?? []
    }

    /// Writes the current values to `UserDefaults`, clamping numbers to their valid range.
    func persist() {
        paperOpacity = Self.clamp(paperOpacity, to: Self.paperOpacityRange)
        fontSize = Self.clamp(fontSize.rounded(), to: Self.fontSizeRange)

        defaults.set(paperOpacity, forKey: Key.paperOpacity)
        defaults.set(fontSize, forKey: Key.fontSize)
        defaults.set(sizeClass.rawValue, forKey: Key.sizeClass)
        defaults.set(fadeEnabled, forKey: Key.fadeEnabled)
        defaults.set(editKey.rawValue, forKey: Key.editKey)
        defaults.set(hideFromScreenCapture, forKey: Key.hideFromScreenCapture)
        defaults.set(hideDuringScreenSharing, forKey: Key.hideDuringScreenSharing)
        defaults.set(showOverFullscreen, forKey: Key.showOverFullscreen)
        defaults.set(callEdge.rawValue, forKey: Key.callEdge)
        defaults.set(showsEdgeTab, forKey: Key.showsEdgeTab)
        defaults.set(smoothPadMotion, forKey: Key.smoothPadMotion)
        defaults.set(defaultColor.rawValue, forKey: Key.defaultColor)
        if let stickerDisplayUUID {
            defaults.set(stickerDisplayUUID, forKey: Key.stickerDisplayUUID)
        } else {
            defaults.removeObject(forKey: Key.stickerDisplayUUID)
        }
        defaults.set(editHintShownCount, forKey: Key.editHintShownCount)
        defaults.set(structurerChoice.rawValue, forKey: Key.structurerChoice)
        defaults.set(ollamaHost, forKey: Key.ollamaHost)
        defaults.set(ollamaModel, forKey: Key.ollamaModel)
        defaults.set(openAIBaseURL, forKey: Key.openAIBaseURL)
        defaults.set(openAIModel, forKey: Key.openAIModel)
        defaults.set(claudeModel, forKey: Key.claudeModel)
        defaults.set(chatGPTModel, forKey: Key.chatGPTModel)
        defaults.set(localServerSpeaksOpenAI, forKey: Key.localServerSpeaksOpenAI)
        defaults.set(cloudConsent, forKey: Key.cloudConsent)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
