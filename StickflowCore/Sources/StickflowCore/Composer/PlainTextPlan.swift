// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// "Stick as is" (spec 4.3): the draft's text becomes a sticker line by line,
/// without any restructuring. The first line is the title.
public enum PlainTextPlan {
    public struct Result: Equatable, Sendable {
        public var title: String
        public var blocks: [Block]

        public init(title: String, blocks: [Block]) {
            self.title = title
            self.blocks = blocks
        }

        public var isEmpty: Bool { title.isEmpty && blocks.isEmpty }
    }

    /// The text is a list already: several lines, or a line that starts with a
    /// marker. Such text is stuck as it is; one paragraph, typed or dictated, is
    /// for a structurer to take apart (spec 8).
    public static func looksStructured(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count == 1, let only = lines.first else { return lines.count > 1 }
        return marker(in: only) != nil
    }

    /// "[] " typed on a Russian layout. The sticker's editor knows the keys by
    /// their place; plain text has only the letters, and "хъ" is not a word.
    static let russianTodoPrefix = "хъ "

    /// - Parameter plainLineKind: what a line without a marker becomes. A sticker
    ///   is a list of things to do, so the default is a task.
    public static func make(from text: String, plainLineKind: Block.Kind = .todo) -> Result {
        var title = ""
        var blocks: [Block] = []
        var isFirst = true

        for rawLine in EditorDocument.normalizedLineBreaks(text).components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let found = marker(in: trimmed)
            if isFirst {
                isFirst = false
                // A marker on the first line still means a block, not a title.
                if found == nil {
                    title = trimmed
                    continue
                }
            }
            let indent = min(leadingIndent(of: rawLine), 2)
            if let found {
                // A marker with nothing after it is not a block.
                guard !found.content.isEmpty else { continue }
                blocks.append(block(kind: found.match.kind, text: found.content, indent: indent, done: found.match.done))
            } else {
                blocks.append(Block(kind: plainLineKind, text: trimmed, indent: indent))
            }
        }
        return Result(title: title, blocks: blocks)
    }

    /// The block shortcut `line` starts with and the text after it. The trailing
    /// space of a marker may have been trimmed away ("-" for "- ").
    private static func marker(in line: String) -> (match: BlockShortcut.Match, content: String)? {
        // The trailing space may have been trimmed away, as with "-".
        if (line + " ").lowercased().hasPrefix(russianTodoPrefix) {
            let rest = String(line.dropFirst(russianTodoPrefix.count)).trimmingCharacters(in: .whitespaces)
            return (BlockShortcut.Match(kind: .todo, done: false, prefixLength: russianTodoPrefix.utf16.count), rest)
        }
        guard let match = BlockShortcut.match(in: line) ?? BlockShortcut.match(in: line + " ") else { return nil }
        let rest = String(line.utf16.dropFirst(match.prefixLength)) ?? ""
        return (match, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func block(kind: LineKind, text: String, indent: Int, done: Bool) -> Block {
        switch kind {
        case .heading2: Block(kind: .heading2, text: text)
        case .bullet: Block(kind: .bullet, text: text, indent: indent)
        case .todo: Block(kind: .todo, text: text, indent: indent, done: done)
        case .text, .title: Block(kind: .text, text: text, indent: indent)
        }
    }

    /// One level per tab or per two leading spaces.
    private static func leadingIndent(of line: String) -> Int {
        var spaces = 0
        var tabs = 0
        for character in line {
            if character == "\t" {
                tabs += 1
            } else if character == " " {
                spaces += 1
            } else {
                break
            }
        }
        return tabs + spaces / 2
    }
}
