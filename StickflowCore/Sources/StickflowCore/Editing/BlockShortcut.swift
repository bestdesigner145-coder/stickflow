// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// Notion-style shortcuts typed at the start of a line (spec 4.8).
public enum BlockShortcut {
    public struct Match: Equatable, Sendable {
        public let kind: LineKind
        public let done: Bool
        /// Length of the typed prefix in UTF-16 units; the editor removes it.
        public let prefixLength: Int
    }

    // Longer prefixes come first so "[x] " is not mistaken for something shorter.
    private static let table: [(prefix: String, kind: LineKind, done: Bool)] = [
        ("[x] ", .todo, true),
        ("[X] ", .todo, true),
        ("[х] ", .todo, true), // Cyrillic "х": easy to hit on a Russian layout
        ("[Х] ", .todo, true),
        ("[ ] ", .todo, false),
        ("[] ", .todo, false),
        ("## ", .heading2, false),
        ("# ", .heading2, false),
        ("- ", .bullet, false),
        ("* ", .bullet, false),
    ]

    /// Returns the shortcut `line` starts with, if any.
    public static func match(in line: String) -> Match? {
        for entry in table where line.hasPrefix(entry.prefix) {
            return Match(kind: entry.kind, done: entry.done, prefixLength: entry.prefix.utf16.count)
        }
        return nil
    }
}
