// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// Keeps the per-line metadata in step with text edits.
///
/// The editor stores text as lines joined by "\n" and a parallel `[LineMeta]`.
/// Every text change is described as "replace this UTF-16 range with that string";
/// `splice` returns the metadata that matches the text after the change.
public enum LineSplicer {
    private static let newline: UInt16 = 0x0A

    /// Number of lines in `text`. An empty string is one empty line.
    public static func lineCount(of text: String) -> Int {
        text.utf16.reduce(into: 1) { count, unit in
            if unit == newline { count += 1 }
        }
    }

    /// Forces `metas` to describe exactly `lineCount` lines: the first is the
    /// title, no other line is. Missing lines become plain text.
    public static func repaired(_ metas: [LineMeta], lineCount: Int) -> [LineMeta] {
        let target = max(lineCount, 1)
        var result = metas
        if result.count > target {
            result.removeSubrange(target...)
        }
        while result.count < target {
            result.append(LineMeta(kind: result.isEmpty ? .title : .text))
        }
        if result[0].kind != .title {
            result[0].convert(to: .title)
        }
        for index in result.indices.dropFirst() where result[index].kind == .title {
            result[index].convert(to: .text)
        }
        return result
    }

    /// Metadata for a line created by pressing Return on a line described by `origin`.
    public static func continuation(of origin: LineMeta, kindAfterTitle: LineKind) -> LineMeta {
        switch origin.kind {
        case .title, .heading2:
            LineMeta(kind: kindAfterTitle)
        case .todo, .bullet, .text:
            LineMeta(kind: origin.kind, indent: origin.indent)
        }
    }

    /// Returns the metadata after replacing `length` UTF-16 units at `location`
    /// in `text` with `replacement`.
    ///
    /// - Parameter kindAfterTitle: kind of a line created right after the title or a sub-heading.
    public static func splice(
        metas: [LineMeta],
        text: String,
        location: Int,
        length: Int,
        replacement: String,
        kindAfterTitle: LineKind = .todo
    ) -> [LineMeta] {
        let units = Array(text.utf16)
        var result = repaired(metas, lineCount: lineCount(of: text))

        let start = min(max(location, 0), units.count)
        let end = min(start + max(length, 0), units.count)

        var firstLine = 0
        var lineStart = 0
        for index in 0..<start where units[index] == newline {
            firstLine += 1
            lineStart = index + 1
        }

        var removedLines = 0
        for index in start..<end where units[index] == newline {
            removedLines += 1
        }

        var insertedLines = 0
        for unit in replacement.utf16 where unit == newline {
            insertedLines += 1
        }

        if removedLines > 0 {
            let lower = firstLine + 1
            let upper = min(firstLine + removedLines, result.count - 1)
            if lower <= upper {
                result.removeSubrange(lower...upper)
            }
        }

        guard insertedLines > 0 else { return result }

        // Return pressed at the very start of a line that has text: the text moves
        // down and must keep its metadata, so the new empty line goes above it.
        var lineHasText = false
        if start < units.count, units[start] != newline {
            lineHasText = true
        }
        let pushesLineDown = firstLine > 0
            && length == 0
            && replacement == "\n"
            && start == lineStart
            && lineHasText

        let origin = result[firstLine]
        let fresh = (0..<insertedLines).map { _ in continuation(of: origin, kindAfterTitle: kindAfterTitle) }
        result.insert(contentsOf: fresh, at: pushesLineDown ? firstLine : firstLine + 1)
        return result
    }
}
