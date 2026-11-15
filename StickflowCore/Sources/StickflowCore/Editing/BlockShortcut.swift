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

    /// Longer prefixes come first so "[x] " is not mistaken for something shorter.
    private static let table: [(prefix: String, kind: LineKind, done: Bool)] = [
        ("[x] ", .todo, true),
        ("[X] ", .todo, true),
        ("[х] ", .todo, true), // Cyrillic "х": easy to hit on a Russian layout
        ("[Х] ", .todo, true),
        ("[ ] ", .todo, false),
        ("[] ", .todo, false),
        ("## ", .heading2, false),
        // Shift+3 twice on a Russian layout, where there is no "#". A single "№ "
        // stays text: "№ 5" is a common way to start a line.
        ("№№ ", .heading2, false),
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

    // MARK: Physical keys

    /// Virtual key codes describe a position on the keyboard, not a character.
    private enum KeyCode {
        static let leftBracket: UInt16 = 33
        static let rightBracket: UInt16 = 30
        static let x: UInt16 = 7
        static let space: UInt16 = 49
    }

    /// Only the bracket shortcuts: on other layouts these keys give letter runs that
    /// are not words ("хъ " in Russian). "#" is not matched by position: the same
    /// key types "§" in German, and "§§ 12–15" is an ordinary way to start a line.
    /// Russian "№№ " is in the text table above, by the author's decision.
    private static let physicalTable: [(keys: [PhysicalKey], kind: LineKind, done: Bool)] = [
        (
            [
                PhysicalKey(code: KeyCode.leftBracket), PhysicalKey(code: KeyCode.x),
                PhysicalKey(code: KeyCode.rightBracket), PhysicalKey(code: KeyCode.space),
            ],
            .todo, true
        ),
        (
            [
                PhysicalKey(code: KeyCode.leftBracket), PhysicalKey(code: KeyCode.space),
                PhysicalKey(code: KeyCode.rightBracket), PhysicalKey(code: KeyCode.space),
            ],
            .todo, false
        ),
        (
            [
                PhysicalKey(code: KeyCode.leftBracket), PhysicalKey(code: KeyCode.rightBracket),
                PhysicalKey(code: KeyCode.space),
            ],
            .todo, false
        ),
    ]

    /// Returns the shortcut spelled by `keys`: the keys pressed since the caret was at
    /// the start of a line, identified by position. This is how "[] " works on a layout
    /// where those keys type letters (on a Russian layout they give "хъ ").
    ///
    /// `prefixLength` assumes one character per key press.
    public static func match(physicalKeys keys: [PhysicalKey]) -> Match? {
        for entry in physicalTable where entry.keys == keys {
            return Match(kind: entry.kind, done: entry.done, prefixLength: keys.count)
        }
        return nil
    }
}

/// A key press identified by where the key is, not by what it types.
public struct PhysicalKey: Equatable, Sendable {
    /// Virtual key code (`NSEvent.keyCode`).
    public let code: UInt16
    public let shift: Bool

    public init(code: UInt16, shift: Bool = false) {
        self.code = code
        self.shift = shift
    }
}
