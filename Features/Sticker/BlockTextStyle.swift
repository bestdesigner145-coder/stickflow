// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

extension NSAttributedString.Key {
    /// Marks sub-heading text that is shown in capitals without changing the stored text.
    static let stickflowUppercase = NSAttributedString.Key("StickflowUppercase")
}

/// Typography of a sticker (spec 6.4). All sizes scale with the base font size.
///
/// At the default 14 pt: text 14/20, title 15/20 semibold, sub-heading 12/16
/// semibold caps with +4% tracking, nested items 13/18.
struct BlockTextStyle: Equatable {
    /// Width of the gutter that holds a checkbox or a bullet.
    static let markerGutter: CGFloat = 20
    static let indentStep: CGFloat = 16
    static let markerSize: CGFloat = 13

    var baseFontSize: CGFloat = 14
    var color: PaperColor = .paper
    var doneOpacity: CGFloat = 0.45
    /// Space kept free at the end of the title line for the "3/5" counter.
    var titleTailReserve: CGFloat = 0

    private var scale: CGFloat { baseFontSize / 14 }

    func font(for meta: LineMeta) -> NSFont {
        switch meta.kind {
        case .title:
            NSFont.systemFont(ofSize: baseFontSize + 1, weight: .semibold)
        case .heading2:
            NSFont.systemFont(ofSize: baseFontSize - 2, weight: .semibold)
        case .todo, .bullet, .text:
            NSFont.systemFont(ofSize: meta.indent > 0 ? baseFontSize - 1 : baseFontSize)
        }
    }

    func lineHeight(for meta: LineMeta) -> CGFloat {
        let base: CGFloat
        switch meta.kind {
        case .title: base = 20
        case .heading2: base = 16
        case .todo, .bullet, .text: base = meta.indent > 0 ? 18 : 20
        }
        return (base * scale).rounded()
    }

    /// Distance from the left edge of the text container to the text of the line.
    func textIndent(for meta: LineMeta) -> CGFloat {
        switch meta.kind {
        case .title, .heading2:
            0
        case .todo, .bullet:
            CGFloat(meta.indent) * Self.indentStep + Self.markerGutter
        case .text:
            CGFloat(meta.indent) * Self.indentStep
        }
    }

    func foregroundColor(for meta: LineMeta) -> NSColor {
        switch meta.kind {
        case .heading2:
            color.textColor(alpha: 0.6)
        case .todo where meta.done:
            color.textColor(alpha: doneOpacity)
        default:
            color.textColor()
        }
    }

    /// Vertical centring offset: with a fixed line height TextKit puts glyphs at the bottom of the line.
    func baselineOffset(for meta: LineMeta) -> CGFloat {
        let font = self.font(for: meta)
        let natural = ceil(font.ascender - font.descender + font.leading)
        return max((self.lineHeight(for: meta) - natural) / 2, 0)
    }

    func attributes(for meta: LineMeta) -> [NSAttributedString.Key: Any] {
        let font = self.font(for: meta)
        let lineHeight = self.lineHeight(for: meta)
        let indent = self.textIndent(for: meta)

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.tailIndent = meta.kind == .title && titleTailReserve > 0 ? -titleTailReserve : 0
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacingBefore = meta.kind == .heading2 ? (6 * scale).rounded() : 0

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .baselineOffset: baselineOffset(for: meta),
            .foregroundColor: foregroundColor(for: meta),
        ]
        if meta.kind == .heading2 {
            attributes[.kern] = font.pointSize * 0.04
            attributes[.stickflowUppercase] = true
        }
        if meta.kind == .todo, meta.done {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = color.textColor(alpha: doneOpacity)
        }
        return attributes
    }
}
