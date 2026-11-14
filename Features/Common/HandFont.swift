// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import CoreText

/// The handwritten font, Caveat (OFL). It is used in two places only: the label
/// on the pad and the question in the draft (spec 6.4). Task text never uses it.
@MainActor
enum HandFont {
    private static var isRegistered = false

    static func font(size: CGFloat) -> NSFont {
        registerIfNeeded()
        let descriptor = NSFontDescriptor(fontAttributes: [.family: "Caveat"])
        if let font = NSFont(descriptor: descriptor, size: size), font.familyName == "Caveat" {
            return font
        }
        // The file is missing from the bundle; stay readable.
        return NSFont.systemFont(ofSize: size * 0.8, weight: .medium)
    }

    private static func registerIfNeeded() {
        guard !isRegistered else { return }
        isRegistered = true
        guard let url = Bundle.main.url(forResource: "Caveat", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}
