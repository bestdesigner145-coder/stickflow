// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import XCTest
@testable import StickflowCore

final class EditorDocumentTests: XCTestCase {
    func testRoundTripKeepsBlocks() {
        let blocks = [
            Block(kind: .heading2, text: "Кошелёк"),
            Block(kind: .todo, text: "Доделать экран"),
            Block(kind: .bullet, text: "пустые состояния", indent: 1),
            Block(kind: .todo, text: "Созвон с разработкой 15:00", done: true, doneAt: Date(timeIntervalSince1970: 1_800_000_000)),
        ]
        let document = EditorDocument(title: "План на день", blocks: blocks)

        XCTAssertEqual(document.text, "План на день\nКошелёк\nДоделать экран\nпустые состояния\nСозвон с разработкой 15:00")
        XCTAssertEqual(document.metas.count, 5)
        XCTAssertEqual(document.metas[0].kind, .title)

        let result = document.titleAndBlocks(dropEmpty: true)
        XCTAssertEqual(result.title, "План на день")
        XCTAssertEqual(result.blocks, blocks)
    }

    func testDropEmptyRemovesBlankLinesAndTrims() {
        let document = EditorDocument(
            text: " Title \n\n  task  \n",
            metas: [.title(), LineMeta(kind: .todo), LineMeta(kind: .todo), LineMeta(kind: .todo)]
        )
        let kept = document.titleAndBlocks(dropEmpty: true)
        XCTAssertEqual(kept.title, "Title")
        XCTAssertEqual(kept.blocks.map(\.text), ["task"])

        let raw = document.titleAndBlocks(dropEmpty: false)
        XCTAssertEqual(raw.blocks.map(\.text), ["", "  task  ", ""])
    }

    func testLineBreaksInsideBlockTextAreFlattened() {
        let document = EditorDocument(title: "A\nB", blocks: [Block(kind: .text, text: "one\r\ntwo\u{2028}three")])
        XCTAssertEqual(document.text, "A B\none two three")
        XCTAssertEqual(document.metas.count, 2)
    }

    func testInitRepairsMismatchedMetas() {
        let document = EditorDocument(text: "a\nb\nc", metas: [LineMeta(kind: .todo)])
        XCTAssertEqual(document.metas.map(\.kind), [.title, .text, .text])
    }

    func testNormalizedLineBreaks() {
        XCTAssertEqual(EditorDocument.normalizedLineBreaks("a\r\nb\rc\u{2029}d"), "a\nb\nc\nd")
    }

    func testEmptyDocument() {
        let document = EditorDocument(title: "", blocks: [])
        XCTAssertEqual(document.text, "")
        XCTAssertEqual(document.metas.map(\.kind), [.title])
        let result = document.titleAndBlocks(dropEmpty: true)
        XCTAssertEqual(result.title, "")
        XCTAssertTrue(result.blocks.isEmpty)
    }
}
