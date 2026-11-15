// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// Kind of an editor line. The first line of a sticker is always its title.
public enum LineKind: String, Sendable, Equatable, CaseIterable {
    case title
    case heading2
    case todo
    case bullet
    case text

    public init(_ kind: Block.Kind) {
        switch kind {
        case .heading2: self = .heading2
        case .todo: self = .todo
        case .bullet: self = .bullet
        case .text: self = .text
        }
    }

    /// Block kind used when the line is saved. A stray title becomes plain text.
    public var blockKind: Block.Kind {
        switch self {
        case .title, .text: .text
        case .heading2: .heading2
        case .todo: .todo
        case .bullet: .bullet
        }
    }

    /// Lines that carry a marker (checkbox or bullet) in the gutter.
    public var hasMarker: Bool { self == .todo || self == .bullet }
}

/// Everything about an editor line except its text.
public struct LineMeta: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: LineKind
    public var indent: Int
    public var done: Bool
    public var doneAt: Date?

    public init(id: UUID = UUID(), kind: LineKind, indent: Int = 0, done: Bool = false, doneAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.indent = min(max(indent, 0), Block.maxIndent)
        self.done = kind == .todo && done
        self.doneAt = self.done ? doneAt : nil
    }

    public init(block: Block) {
        self.init(id: block.id, kind: LineKind(block.kind), indent: block.indent, done: block.done, doneAt: block.doneAt)
    }

    public static func title(id: UUID = UUID()) -> LineMeta {
        LineMeta(id: id, kind: .title)
    }

    public func block(text: String) -> Block {
        Block(id: id, kind: kind.blockKind, text: text, indent: indent, done: done, doneAt: doneAt)
    }

    /// Flips a task between open and done. Does nothing for other kinds.
    public mutating func toggleDone(now: Date = Date()) {
        guard kind == .todo else { return }
        done.toggle()
        doneAt = done ? now : nil
    }

    /// Changes nesting by `delta`, clamped to `0...Block.maxIndent`. Titles and headings never nest.
    public mutating func shiftIndent(by delta: Int) {
        guard kind != .title, kind != .heading2 else { return }
        indent = min(max(indent + delta, 0), Block.maxIndent)
    }

    /// Turns the line into another kind, dropping state that no longer applies.
    public mutating func convert(to newKind: LineKind, done newDone: Bool = false, now: Date = Date()) {
        kind = newKind
        if newKind == .todo {
            done = newDone
            doneAt = newDone ? (doneAt ?? now) : nil
        } else {
            done = false
            doneAt = nil
        }
        if newKind == .title || newKind == .heading2 {
            indent = 0
        }
    }
}
