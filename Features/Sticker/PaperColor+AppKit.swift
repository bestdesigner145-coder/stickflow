// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

extension NSColor {
    /// Creates an sRGB colour from 0xRRGGBB.
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Creates an sRGB colour from 0xRRGGBB with every channel multiplied by `1 - amount`.
    convenience init(rgb: UInt32, darkenedBy amount: CGFloat) {
        let factor = max(0, 1 - amount)
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255 * factor,
            green: CGFloat((rgb >> 8) & 0xFF) / 255 * factor,
            blue: CGFloat(rgb & 0xFF) / 255 * factor,
            alpha: 1
        )
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension PaperColor {
    func paperColor(dark: Bool) -> NSColor {
        NSColor(rgb: palette.paper(dark: dark))
    }

    /// The glue strip: same colour, 4% darker (spec 6.2).
    func stripColor(dark: Bool) -> NSColor {
        NSColor(rgb: palette.paper(dark: dark), darkenedBy: 0.04)
    }

    /// Text colour that follows the appearance of the view it is drawn in.
    func textColor(alpha: CGFloat = 1) -> NSColor {
        let palette = self.palette
        return NSColor(name: nil) { appearance in
            NSColor(rgb: palette.text(dark: appearance.isDark), alpha: alpha)
        }
    }
}
