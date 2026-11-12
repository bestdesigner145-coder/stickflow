// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import XCTest
@testable import StickflowCore

final class ModelTests: XCTestCase {
    func testTaskCountCountsOnlyTodos() {
        let sticker = Sticker(
            title: "План",
            blocks: [
                Block(kind: .heading2, text: "Кошелёк"),
                Block(kind: .todo, text: "a", done: true),
                Block(kind: .todo, text: "b"),
                Block(kind: .bullet, text: "c"),
            ]
        )
        XCTAssertEqual(sticker.taskCount, TaskCount(done: 1, total: 2))
        XCTAssertEqual(sticker.taskCount.label, "1/2")
        XCTAssertFalse(sticker.taskCount.allDone)
    }

    func testStatusAfterPeeling() {
        let open = Sticker(blocks: [Block(kind: .todo, text: "a")])
        XCTAssertEqual(open.statusAfterPeeling, .draft)

        let finished = Sticker(blocks: [Block(kind: .todo, text: "a", done: true)])
        XCTAssertEqual(finished.statusAfterPeeling, .done)

        let noTasks = Sticker(title: "Note", blocks: [Block(kind: .text, text: "just text")])
        XCTAssertEqual(noTasks.statusAfterPeeling, .done)
    }

    func testIsBlank() {
        XCTAssertTrue(Sticker().isBlank)
        XCTAssertTrue(Sticker(title: "  ", blocks: [Block(kind: .todo, text: " ")]).isBlank)
        XCTAssertFalse(Sticker(title: "x").isBlank)
        XCTAssertFalse(Sticker(blocks: [Block(kind: .todo, text: "x")]).isBlank)
    }

    func testBlockInitClampsIndentAndDoneState() {
        let block = Block(kind: .bullet, text: "x", indent: 9, done: true, doneAt: Date())
        XCTAssertEqual(block.indent, Block.maxIndent)
        XCTAssertFalse(block.done, "only tasks can be done")
        XCTAssertNil(block.doneAt)
    }

    func testStickerJSONRoundTrip() throws {
        let sticker = Sticker(
            title: "План на день",
            blocks: [Block(kind: .todo, text: "Созвон", done: true, doneAt: Date(timeIntervalSince1970: 1_800_000_000))],
            status: .active,
            color: .sage,
            placement: Placement(displayKey: "ABC@1728x1117", positions: ["ABC@1728x1117": StickerPoint(x: 1400, y: 150)]),
            source: .dictated,
            rawInput: "ну короче созвон",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let data = try JSONEncoder().encode(sticker)
        let decoded = try JSONDecoder().decode(Sticker.self, from: data)
        XCTAssertEqual(decoded, sticker)
    }

    func testDisplayKey() {
        let key = DisplayKey.make(uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230", width: 1728, height: 1117.4)
        XCTAssertEqual(key, "37D8832A-2D66-02CA-B9F7-8F30A301B230@1728x1117")
        XCTAssertEqual(DisplayKey.uuid(from: key), "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        XCTAssertNil(DisplayKey.uuid(from: "no-separator"))
        XCTAssertNil(DisplayKey.uuid(from: "@1x1"))
    }

    func testPaletteMatchesSpec() {
        XCTAssertEqual(PaperColor.paper.palette.paper(dark: false), 0xF2EFE8)
        XCTAssertEqual(PaperColor.paper.palette.paper(dark: true), 0x34332F)
        XCTAssertEqual(PaperColor.cream.palette.text(dark: false), 0x2B2718)
        XCTAssertEqual(PaperColor.sage.palette.text(dark: true), 0xE0E8D3)
    }

    func testShortcuts() {
        XCTAssertEqual(BlockShortcut.match(in: "[] milk"), BlockShortcut.Match(kind: .todo, done: false, prefixLength: 3))
        XCTAssertEqual(BlockShortcut.match(in: "[ ] milk"), BlockShortcut.Match(kind: .todo, done: false, prefixLength: 4))
        XCTAssertEqual(BlockShortcut.match(in: "[x] milk"), BlockShortcut.Match(kind: .todo, done: true, prefixLength: 4))
        XCTAssertEqual(BlockShortcut.match(in: "## Кошелёк"), BlockShortcut.Match(kind: .heading2, done: false, prefixLength: 3))
        XCTAssertEqual(BlockShortcut.match(in: "# Кошелёк"), BlockShortcut.Match(kind: .heading2, done: false, prefixLength: 2))
        XCTAssertEqual(BlockShortcut.match(in: "- item"), BlockShortcut.Match(kind: .bullet, done: false, prefixLength: 2))
        XCTAssertEqual(BlockShortcut.match(in: "* item"), BlockShortcut.Match(kind: .bullet, done: false, prefixLength: 2))
        XCTAssertNil(BlockShortcut.match(in: "-item"))
        XCTAssertNil(BlockShortcut.match(in: "plain"))
    }

    func testLineMetaOperations() {
        var meta = LineMeta(kind: .todo)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        meta.toggleDone(now: now)
        XCTAssertTrue(meta.done)
        XCTAssertEqual(meta.doneAt, now)
        meta.toggleDone(now: now)
        XCTAssertFalse(meta.done)
        XCTAssertNil(meta.doneAt)

        meta.shiftIndent(by: 5)
        XCTAssertEqual(meta.indent, Block.maxIndent)
        meta.shiftIndent(by: -9)
        XCTAssertEqual(meta.indent, 0)

        meta.toggleDone(now: now)
        meta.convert(to: .bullet)
        XCTAssertFalse(meta.done, "converting away from a task clears completion")

        var heading = LineMeta(kind: .text, indent: 2)
        heading.convert(to: .heading2)
        XCTAssertEqual(heading.indent, 0)
        heading.shiftIndent(by: 1)
        XCTAssertEqual(heading.indent, 0, "headings never nest")
    }
}
