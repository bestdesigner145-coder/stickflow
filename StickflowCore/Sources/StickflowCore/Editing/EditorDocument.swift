// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// A sticker in the shape the editor works with: plain text plus one `LineMeta` per line.
public struct EditorDocument: Equatable, Sendable {
    /// Lines joined by "\n". Line 0 is the title.
    public var text: String
    /// `metas.count` always equals the number of lines in `text`.
    public var metas: [LineMeta]

    public init(text: String, metas: [LineMeta]) {
        self.text = text
        self.metas = LineSplicer.repaired(metas, lineCount: LineSplicer.lineCount(of: text))
    }

    public init(title: String, blocks: [Block]) {
        var lines = [Self.singleLine(title)]
        var metas = [LineMeta.title()]
        lines.reserveCapacity(blocks.count + 1)
        metas.reserveCapacity(blocks.count + 1)
        for block in blocks {
            lines.append(Self.singleLine(block.text))
            metas.append(LineMeta(block: block))
        }
        self.text = lines.joined(separator: "\n")
        self.metas = metas
    }

    public var lines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Converts the document back into a title and blocks.
    ///
    /// - Parameter dropEmpty: when true, lines without text are left out and the
    ///   rest is trimmed. Used when editing ends; while typing we keep everything.
    public func titleAndBlocks(dropEmpty: Bool) -> (title: String, blocks: [Block]) {
        let lines = self.lines
        let title = (lines.first ?? "").trimmingCharacters(in: .whitespaces)
        var blocks: [Block] = []
        blocks.reserveCapacity(max(lines.count - 1, 0))
        for index in lines.indices.dropFirst() {
            let meta = index < metas.count ? metas[index] : LineMeta(kind: .text)
            let text = dropEmpty ? lines[index].trimmingCharacters(in: .whitespaces) : lines[index]
            if dropEmpty, text.isEmpty { continue }
            blocks.append(meta.block(text: text))
        }
        return (title, blocks)
    }

    /// Replaces every kind of line break with a space: a block is always one line.
    public static func singleLine(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: " ")
        for separator in ["\n", "\r", "\u{2028}", "\u{2029}"] {
            result = result.replacingOccurrences(of: separator, with: " ")
        }
        return result
    }

    /// Normalises pasted text so that "\n" is the only line break.
    public static func normalizedLineBreaks(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        for separator in ["\r", "\u{2028}", "\u{2029}"] {
            result = result.replacingOccurrences(of: separator, with: "\n")
        }
        return result
    }
}
