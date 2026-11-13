// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import GRDB
import StickflowCore
import XCTest

final class StickerRepositoryTests: XCTestCase {
    private let moment = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRepository() throws -> StickerRepository {
        StickerRepository(database: try AppDatabase.inMemory())
    }

    private func makeSticker(status: Sticker.Status = .active, createdAt: Date? = nil) -> Sticker {
        Sticker(
            title: "План на день",
            blocks: [
                Block(kind: .heading2, text: "Кошелёк"),
                Block(kind: .todo, text: "Доделать экран"),
                Block(kind: .bullet, text: "пустые состояния", indent: 1),
                Block(kind: .todo, text: "Созвон с разработкой 15:00", done: true, doneAt: moment),
            ],
            status: status,
            color: .cream,
            placement: Placement(
                displayKey: "DISPLAY@1728x1117",
                positions: ["DISPLAY@1728x1117": StickerPoint(x: 1476, y: 145)]
            ),
            source: .typed,
            rawInput: "сначала экран кошелька, потом созвон в три",
            createdAt: createdAt ?? moment,
            stuckAt: moment
        )
    }

    func testSaveAndLoadRoundTrip() throws {
        let repository = try makeRepository()
        let sticker = makeSticker()

        try repository.save(sticker)

        XCTAssertEqual(try repository.sticker(id: sticker.id), sticker)
        XCTAssertEqual(try repository.stickers(status: .active), [sticker])
    }

    func testSaveReplacesExistingRow() throws {
        let repository = try makeRepository()
        var sticker = makeSticker()
        try repository.save(sticker)

        sticker.title = "Другой план"
        sticker.blocks[1].done = true
        sticker.updatedAt = moment.addingTimeInterval(60)
        try repository.save(sticker)

        XCTAssertEqual(try repository.totalCount(), 1)
        XCTAssertEqual(try repository.sticker(id: sticker.id), sticker)
    }

    func testFilterByStatusAndOrderByCreation() throws {
        let repository = try makeRepository()
        let newer = makeSticker(createdAt: moment.addingTimeInterval(120))
        let older = makeSticker(createdAt: moment)
        let draft = makeSticker(status: .draft)
        try repository.save(newer)
        try repository.save(older)
        try repository.save(draft)

        XCTAssertEqual(try repository.stickers(status: .active).map(\.id), [older.id, newer.id])
        XCTAssertEqual(try repository.stickers(status: .draft).map(\.id), [draft.id])
        XCTAssertTrue(try repository.stickers(status: .done).isEmpty)
    }

    func testSoftDeletedStickersAreHidden() throws {
        let repository = try makeRepository()
        var sticker = makeSticker()
        sticker.deletedAt = moment
        try repository.save(sticker)

        XCTAssertTrue(try repository.stickers(status: .active).isEmpty)
        XCTAssertEqual(try repository.totalCount(), 1, "the row stays for a future sync")
    }

    func testLastPeeledIsTheNewestStickerStillOffScreen() throws {
        let repository = try makeRepository()
        XCTAssertNil(try repository.lastPeeled())

        var older = makeSticker(status: .draft)
        older.peeledAt = moment
        var newer = makeSticker(status: .done)
        newer.peeledAt = moment.addingTimeInterval(60)
        // Peeled once, then put back on screen: no longer a candidate.
        var restored = makeSticker(status: .active)
        restored.peeledAt = moment.addingTimeInterval(120)
        var deleted = makeSticker(status: .draft)
        deleted.peeledAt = moment.addingTimeInterval(180)
        deleted.deletedAt = moment.addingTimeInterval(200)
        let neverPeeled = makeSticker(status: .draft)

        for sticker in [older, newer, restored, deleted, neverPeeled] {
            try repository.save(sticker)
        }

        XCTAssertEqual(try repository.lastPeeled()?.id, newer.id)
    }

    func testUnknownEnumValuesFallBackInsteadOfFailing() throws {
        let repository = try makeRepository()
        let sticker = makeSticker()
        try repository.save(sticker)

        // Simulate a row written by a newer app version.
        try repository.database.queue.write { db in
            try db.execute(
                sql: "UPDATE sticker SET color = 'neon', source = 'telepathy' WHERE id = ?",
                arguments: [sticker.id.uuidString]
            )
        }

        let loaded = try XCTUnwrap(try repository.sticker(id: sticker.id))
        XCTAssertEqual(loaded.color, .paper)
        XCTAssertEqual(loaded.source, .typed)
        XCTAssertEqual(loaded.blocks, sticker.blocks)
    }

    func testMigrationsCanRunTwice() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue: queue)
        _ = try AppDatabase(queue: queue)

        let tableExists = try queue.read { db in
            try db.tableExists(StickerRecord.databaseTableName)
        }
        XCTAssertTrue(tableExists)
    }
}
