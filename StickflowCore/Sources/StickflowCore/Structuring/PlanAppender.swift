// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// The "add to a sticker" mode (spec 8.3): new items go into the sticker that is
/// already there. A section whose heading the sticker has (case does not matter)
/// grows at its end; items without a heading join the lines above the first
/// heading; any other section is added at the bottom. What the sticker already
/// says is not repeated.
public enum PlanAppender {
    public struct Result: Equatable, Sendable {
        public var blocks: [Block]
        /// Positions of the new lines in `blocks`, for highlighting them.
        public var added: [Int]
    }

    public static func append(_ plan: NotePlan, to blocks: [Block]) -> Result {
        func key(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var lines = blocks.map { (block: $0, isNew: false) }
        var known = Set(blocks.map { key($0.text) })

        for section in plan.sections {
            var fresh: [Block] = []
            for item in section.items {
                let single = NotePlan(title: "", sections: [NotePlan.Section(items: [item])]).blocks()
                guard let first = single.first, !known.contains(key(first.text)) else { continue }
                known.insert(key(first.text))
                fresh.append(contentsOf: single)
            }
            guard !fresh.isEmpty else { continue }

            let headings = lines.indices.filter { lines[$0].block.kind == .heading2 }
            var position = lines.count
            if let heading = section.heading, !key(heading).isEmpty {
                if let own = headings.first(where: { key(lines[$0].block.text) == key(heading) }) {
                    position = headings.first { $0 > own } ?? lines.count
                } else {
                    fresh.insert(Block(kind: .heading2, text: heading), at: 0)
                }
            } else {
                position = headings.first ?? lines.count
            }
            lines.insert(contentsOf: fresh.map { (block: $0, isNew: true) }, at: position)
        }
        return Result(blocks: lines.map { $0.block }, added: lines.indices.filter { lines[$0].isNew })
    }
}

public extension NotePlan {
    /// The plan as plain lines, the way the draft shows it before it is stuck:
    /// the title, headings, "☐" for a task, "•" for a point, details indented.
    func previewLines(includingTitle: Bool = true) -> [String] {
        var lines: [String] = includingTitle && !title.isEmpty ? [title] : []
        for block in blocks() {
            let indent = String(repeating: "    ", count: block.indent)
            switch block.kind {
            case .heading2: lines.append(block.text.uppercased())
            case .todo: lines.append(indent + "☐ " + block.text)
            default: lines.append(indent + "• " + block.text)
            }
        }
        return lines
    }
}
