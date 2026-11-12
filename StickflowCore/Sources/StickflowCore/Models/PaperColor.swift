// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// The three muted paper colours (spec 6.2). Values are 0xRRGGBB.
public enum PaperColor: String, Codable, Sendable, CaseIterable {
    case paper
    case cream
    case sage

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
        case .paper:
            Palette(paperLight: 0xF2EFE8, paperDark: 0x34332F, textLight: 0x25241F, textDark: 0xE9E6DE)
        case .cream:
            Palette(paperLight: 0xF3E9C6, paperDark: 0x3A3628, textLight: 0x2B2718, textDark: 0xEDE6CC)
        case .sage:
            Palette(paperLight: 0xE1E7D5, paperDark: 0x2F3529, textLight: 0x21281A, textDark: 0xE0E8D3)
        }
    }
}
