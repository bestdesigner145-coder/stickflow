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
    /// Experimental: take stickers off the screen while something records or shares it.
    var hideWhileScreenIsCaptured: Bool
    var showOverFullscreen: Bool
    var defaultColor: PaperColor
    /// UUID of the display stickers live on; `nil` means the display with the menu bar.
    var stickerDisplayUUID: String?
    /// How many times the "hold ⌥ to edit" hint has been shown.
    var editHintShownCount: Int

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
        static let hideWhileScreenIsCaptured = "hideWhileScreenIsCaptured"
        static let showOverFullscreen = "showOverFullscreen"
        static let defaultColor = "defaultColor"
        static let stickerDisplayUUID = "stickerDisplayUUID"
        static let editHintShownCount = "editHintShownCount"
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
            Key.hideWhileScreenIsCaptured: false,
            Key.showOverFullscreen: false,
            Key.defaultColor: PaperColor.default.rawValue,
            Key.editHintShownCount: 0,
        ])

        paperOpacity = Self.clamp(defaults.double(forKey: Key.paperOpacity), to: Self.paperOpacityRange)
        fontSize = Self.clamp(defaults.double(forKey: Key.fontSize).rounded(), to: Self.fontSizeRange)
        sizeClass = defaults.string(forKey: Key.sizeClass).flatMap(StickerSizeClass.init(rawValue:)) ?? .medium
        fadeEnabled = defaults.bool(forKey: Key.fadeEnabled)
        editKey = defaults.string(forKey: Key.editKey).flatMap(EditKey.init(rawValue:)) ?? .option
        hideFromScreenCapture = defaults.bool(forKey: Key.hideFromScreenCapture)
        hideWhileScreenIsCaptured = defaults.bool(forKey: Key.hideWhileScreenIsCaptured)
        showOverFullscreen = defaults.bool(forKey: Key.showOverFullscreen)
        defaultColor = defaults.string(forKey: Key.defaultColor).flatMap { PaperColor(stored: $0) } ?? .default
        stickerDisplayUUID = defaults.string(forKey: Key.stickerDisplayUUID)
        editHintShownCount = defaults.integer(forKey: Key.editHintShownCount)
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
        defaults.set(hideWhileScreenIsCaptured, forKey: Key.hideWhileScreenIsCaptured)
        defaults.set(showOverFullscreen, forKey: Key.showOverFullscreen)
        defaults.set(defaultColor.rawValue, forKey: Key.defaultColor)
        if let stickerDisplayUUID {
            defaults.set(stickerDisplayUUID, forKey: Key.stickerDisplayUUID)
        } else {
            defaults.removeObject(forKey: Key.stickerDisplayUUID)
        }
        defaults.set(editHintShownCount, forKey: Key.editHintShownCount)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
