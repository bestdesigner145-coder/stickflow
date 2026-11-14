// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
import GRDB

/// Owns the SQLite connection and the schema migrations.
///
/// Migrations are append-only: never edit a registered migration, add a new one.
/// CI checks that a database created by any released version still migrates.
struct AppDatabase {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) throws {
        self.queue = queue
        try Self.migrator.migrate(queue)
    }

    /// Opens (and creates if needed) the database file at `url`.
    static func onDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try AppDatabase(queue: DatabaseQueue(path: url.path))
    }

    /// A throwaway database for tests.
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(queue: DatabaseQueue())
    }

    /// `~/Library/Application Support/Stickflow/db.sqlite` (spec 10.1).
    static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("Stickflow", isDirectory: true)
            .appendingPathComponent("db.sqlite", isDirectory: false)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_stickers") { db in
            try db.create(table: StickerRecord.databaseTableName) { table in
                table.primaryKey("id", .text)
                table.column("title", .text).notNull()
                table.column("blocks", .text).notNull()
                table.column("status", .text).notNull().indexed()
                table.column("color", .text).notNull()
                table.column("placement", .text)
                table.column("source", .text).notNull()
                table.column("rawInput", .text)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.column("stuckAt", .datetime)
                table.column("peeledAt", .datetime)
                table.column("deletedAt", .datetime)
            }
        }

        return migrator
    }
}
