// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// One line of a sticker below its title: a task, a bullet, a sub-heading or plain text.
public struct Block: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case heading2
        case todo
        case bullet
        case text
    }

    /// Deepest nesting level a block can have (spec 4.8).
    public static let maxIndent = 2

    public let id: UUID
    public var kind: Kind
    public var text: String
    public var indent: Int
    public var done: Bool
    public var doneAt: Date?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        indent: Int = 0,
        done: Bool = false,
        doneAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.indent = min(max(indent, 0), Self.maxIndent)
        self.done = kind == .todo && done
        self.doneAt = self.done ? doneAt : nil
    }
}
