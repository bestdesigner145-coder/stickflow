// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
import GRDB
import StickflowCore

/// Reads and writes stickers. The only place that knows about SQL.
struct StickerRepository {
    let database: AppDatabase

    /// Inserts the sticker or replaces the stored copy with the same id.
    func save(_ sticker: Sticker) throws {
        let record = try StickerRecord(sticker)
        try database.queue.write { db in
            try record.save(db)
        }
    }

    func sticker(id: UUID) throws -> Sticker? {
        let record = try database.queue.read { db in
            try StickerRecord.fetchOne(db, key: id.uuidString)
        }
        return try record?.sticker()
    }

    /// Stickers with the given status that are not soft-deleted, oldest first.
    func stickers(status: Sticker.Status) throws -> [Sticker] {
        let records = try database.queue.read { db in
            try StickerRecord
                .filter(Column("status") == status.rawValue)
                .filter(Column("deletedAt") == nil)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
        return try records.map { try $0.sticker() }
    }

    /// The most recently peeled sticker that is still off screen, if any.
    func lastPeeled() throws -> Sticker? {
        let offScreen = [Sticker.Status.draft.rawValue, Sticker.Status.done.rawValue]
        let record = try database.queue.read { db in
            try StickerRecord
                .filter(Column("peeledAt") != nil)
                .filter(Column("deletedAt") == nil)
                .filter(offScreen.contains(Column("status")))
                .order(Column("peeledAt").desc)
                .fetchOne(db)
        }
        return try record?.sticker()
    }

    /// Number of stored rows, including soft-deleted ones.
    func totalCount() throws -> Int {
        try database.queue.read { db in
            try StickerRecord.fetchCount(db)
        }
    }
}
