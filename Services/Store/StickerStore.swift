// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
import StickflowCore

/// Where stickers are kept, behind a protocol so that tests can do without a database (spec 17.4).
protocol StickerStore {
    /// Inserts the sticker or replaces the stored copy with the same id.
    func save(_ sticker: Sticker) throws
    func sticker(id: UUID) throws -> Sticker?
    /// Stickers with the given status that are not soft-deleted, oldest first.
    func stickers(status: Sticker.Status) throws -> [Sticker]
    /// The most recently peeled sticker that is still off screen, if any.
    func lastPeeled() throws -> Sticker?
}

extension StickerRepository: StickerStore {}

/// Keeps stickers in memory and forgets them when it goes away.
final class InMemoryStickerStore: StickerStore {
    private var stickersByID: [UUID: Sticker] = [:]

    func save(_ sticker: Sticker) throws {
        stickersByID[sticker.id] = sticker
    }

    func sticker(id: UUID) throws -> Sticker? {
        stickersByID[id]
    }

    func stickers(status: Sticker.Status) throws -> [Sticker] {
        stickersByID.values
            .filter { $0.status == status && $0.deletedAt == nil }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func lastPeeled() throws -> Sticker? {
        stickersByID.values
            .filter { $0.peeledAt != nil && $0.deletedAt == nil && ($0.status == .draft || $0.status == .done) }
            .max { ($0.peeledAt ?? .distantPast) < ($1.peeledAt ?? .distantPast) }
    }
}
