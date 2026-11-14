// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// Paper colours (spec 6.2). Classic sticky-note hues, calm but saturated enough
/// to stand out on both a white and a black background. Values are 0xRRGGBB.
public enum PaperColor: String, Codable, Sendable, CaseIterable {
    case yellow
    case blue
    case green
    case pink
    case paper

    /// Colour used for new stickers until the user picks another one.
    public static let `default`: PaperColor = .yellow

    /// Reads a stored value, including names used by earlier builds
    /// (`cream` became `yellow`, `sage` became `green`).
    public init?(stored raw: String) {
        switch raw {
        case "cream": self = .yellow
        case "sage": self = .green
        default: self.init(rawValue: raw)
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaperColor(stored: raw) ?? .default
    }

    public struct Palette: Equatable, Sendable {
        public let paperLight: UInt32
        public let paperDark: UInt32
        public let textLight: UInt32
        public let textDark: UInt32

        public func paper(dark: Bool) -> UInt32 { dark ? paperDark : paperLight }
        public func text(dark: Bool) -> UInt32 { dark ? textDark : textLight }
    }

    public var palette: Palette {
        switch self {
        case .yellow:
            Palette(paperLight: 0xF8E38C, paperDark: 0x5C4F1E, textLight: 0x2E2610, textDark: 0xFBF0C6)
        case .blue:
            Palette(paperLight: 0xBCDAF5, paperDark: 0x1F3B57, textLight: 0x0F2538, textDark: 0xDCEBFA)
        case .green:
            Palette(paperLight: 0xC6E6B0, paperDark: 0x2B4526, textLight: 0x162A0F, textDark: 0xDDF0D1)
        case .pink:
            Palette(paperLight: 0xF6C6D4, paperDark: 0x55283B, textLight: 0x3A1322, textDark: 0xF9DCE5)
        case .paper:
            Palette(paperLight: 0xF2EFE8, paperDark: 0x34332F, textLight: 0x25241F, textDark: 0xE9E6DE)
        }
    }
}
