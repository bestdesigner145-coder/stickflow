// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// A note stuck on top of all windows (spec 10.2).
public struct Sticker: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        /// Visible on screen.
        case active
        /// Not on screen and has open tasks, or never stuck.
        case draft
        /// Peeled off with every task completed.
        case done
        /// Deleted by the user; kept for soft deletion.
        case trashed
    }

    public enum Source: String, Codable, Sendable, CaseIterable {
        case typed
        case dictated
        case mcp
        case duplicated
    }

    public let id: UUID
    public var title: String
    public var blocks: [Block]
    public var status: Status
    public var color: PaperColor
    public var placement: Placement?
    public var source: Source
    /// Text as it was before structuring; used for undo and debugging.
    public var rawInput: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var stuckAt: Date?
    public var peeledAt: Date?
    /// Soft deletion marker, so a future sync can propagate removals.
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String = "",
        blocks: [Block] = [],
        status: Status = .active,
        color: PaperColor = .paper,
        placement: Placement? = nil,
        source: Source = .typed,
        rawInput: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        stuckAt: Date? = nil,
        peeledAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.blocks = blocks
        self.status = status
        self.color = color
        self.placement = placement
        self.source = source
        self.rawInput = rawInput
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.stuckAt = stuckAt
        self.peeledAt = peeledAt
        self.deletedAt = deletedAt
    }

    /// Completed and total task counts, shown as "3/5" on the sticker.
    public var taskCount: TaskCount {
        var done = 0
        var total = 0
        for block in blocks where block.kind == .todo {
            total += 1
            if block.done { done += 1 }
        }
        return TaskCount(done: done, total: total)
    }

    /// True when there is neither a title nor any text worth keeping.
    public var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && blocks.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Status a sticker gets when it is peeled off the screen (spec 4.10).
    public var statusAfterPeeling: Status {
        let count = taskCount
        return count.total > 0 && count.done < count.total ? .draft : .done
    }
}

public struct TaskCount: Equatable, Sendable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    public var hasTasks: Bool { total > 0 }
    public var allDone: Bool { total > 0 && done == total }
    public var label: String { "\(done)/\(total)" }
}
