// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import CoreText

/// Shows sub-headings in capitals without touching the stored text.
///
/// TextKit has no "text-transform: uppercase", so the glyphs are swapped while
/// the layout manager generates them. Any character that cannot be mapped
/// one-to-one keeps its original glyph, so the worst case is a lower-case letter.
final class UppercaseGlyphGenerator: NSObject, NSLayoutManagerDelegate {
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let storage = layoutManager.textStorage, glyphRange.length > 0 else { return 0 }
        let text = storage.string as NSString
        let count = glyphRange.length

        var output = [CGGlyph](repeating: 0, count: count)
        var changed = false

        for index in 0..<count {
            output[index] = glyphs[index]

            let charIndex = charIndexes[index]
            guard charIndex >= 0, charIndex < text.length else { continue }
            guard storage.attribute(.stickflowUppercase, at: charIndex, effectiveRange: nil) != nil else { continue }

            let property = props[index]
            if property.contains(.controlCharacter) || property.contains(.null) { continue }

            let unit = text.character(at: charIndex)
            if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) { continue }

            let upper = Array(String(decoding: [unit], as: UTF16.self).uppercased().utf16)
            guard upper.count == 1, upper[0] != unit else { continue }

            var character: UniChar = upper[0]
            var glyph: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(aFont as CTFont, &character, &glyph, 1), glyph != 0 {
                output[index] = glyph
                changed = true
            }
        }

        guard changed else { return 0 }
        output.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            layoutManager.setGlyphs(
                base,
                properties: props,
                characterIndexes: charIndexes,
                font: aFont,
                forGlyphRange: glyphRange
            )
        }
        return count
    }
}
