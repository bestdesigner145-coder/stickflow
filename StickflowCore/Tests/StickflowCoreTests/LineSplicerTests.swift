// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import XCTest
@testable import StickflowCore

final class LineSplicerTests: XCTestCase {
    private func metas(_ kinds: LineKind...) -> [LineMeta] {
        kinds.map { LineMeta(kind: $0) }
    }

    private func kinds(_ metas: [LineMeta]) -> [LineKind] {
        metas.map(\.kind)
    }

    func testLineCount() {
        XCTAssertEqual(LineSplicer.lineCount(of: ""), 1)
        XCTAssertEqual(LineSplicer.lineCount(of: "a"), 1)
        XCTAssertEqual(LineSplicer.lineCount(of: "a\n"), 2)
        XCTAssertEqual(LineSplicer.lineCount(of: "a\nb\nc"), 3)
    }

    func testRepairPadsTruncatesAndKeepsTitleFirst() {
        XCTAssertEqual(kinds(LineSplicer.repaired([], lineCount: 2)), [.title, .text])
        XCTAssertEqual(kinds(LineSplicer.repaired(metas(.title, .todo, .todo), lineCount: 2)), [.title, .todo])
        XCTAssertEqual(kinds(LineSplicer.repaired(metas(.todo, .title), lineCount: 2)), [.title, .text])
    }

    func testTypingInsideALineKeepsMetas() {
        let before = metas(.title, .todo)
        let after = LineSplicer.splice(metas: before, text: "Plan\nCall", location: 9, length: 0, replacement: "s")
        XCTAssertEqual(after, before)
    }

    func testReturnAfterTitleCreatesConfiguredKind() {
        let before = metas(.title)
        let todo = LineSplicer.splice(metas: before, text: "Plan", location: 4, length: 0, replacement: "\n", kindAfterTitle: .todo)
        XCTAssertEqual(kinds(todo), [.title, .todo])
        let text = LineSplicer.splice(metas: before, text: "Plan", location: 4, length: 0, replacement: "\n", kindAfterTitle: .text)
        XCTAssertEqual(kinds(text), [.title, .text])
    }

    func testReturnAtEndOfTodoContinuesTodoWithSameIndent() {
        var task = LineMeta(kind: .todo, indent: 1, done: true, doneAt: Date())
        task.id = UUID()
        let before = [LineMeta.title(), task]
        let after = LineSplicer.splice(metas: before, text: "Plan\nCall", location: 9, length: 0, replacement: "\n")
        XCTAssertEqual(kinds(after), [.title, .todo, .todo])
        XCTAssertEqual(after[1], task, "the existing task keeps its identity and state")
        XCTAssertEqual(after[2].indent, 1)
        XCTAssertFalse(after[2].done, "a new task starts open")
        XCTAssertNotEqual(after[2].id, task.id)
    }

    func testReturnAtStartOfLinePushesItDownWithItsState() {
        let task = LineMeta(kind: .todo, done: true, doneAt: Date())
        let before = [LineMeta.title(), task]
        // Caret right before "Call".
        let after = LineSplicer.splice(metas: before, text: "Plan\nCall", location: 5, length: 0, replacement: "\n")
        XCTAssertEqual(kinds(after), [.title, .todo, .todo])
        XCTAssertFalse(after[1].done, "the new empty line is above")
        XCTAssertEqual(after[2], task, "the text moved down together with its metadata")
    }

    func testReturnOnEmptyLineInsertsBelow() {
        let before = metas(.title, .bullet)
        let after = LineSplicer.splice(metas: before, text: "Plan\n", location: 5, length: 0, replacement: "\n")
        XCTAssertEqual(kinds(after), [.title, .bullet, .bullet])
        XCTAssertEqual(after[1], before[1])
    }

    func testDeletingALineBreakMergesIntoTheUpperLine() {
        let before = metas(.title, .todo, .bullet)
        // Remove the "\n" between "A" and "B": "T\nA\nB" -> "T\nAB".
        let after = LineSplicer.splice(metas: before, text: "T\nA\nB", location: 3, length: 1, replacement: "")
        XCTAssertEqual(after, [before[0], before[1]])
    }

    func testReplacingSeveralLinesWithOne() {
        let before = metas(.title, .todo, .bullet, .text)
        // Select from inside line 1 to inside line 3 and type "x".
        let after = LineSplicer.splice(metas: before, text: "T\nAA\nBB\nCC", location: 3, length: 6, replacement: "x")
        XCTAssertEqual(after, [before[0], before[1]])
    }

    func testPastingSeveralLines() {
        let before = metas(.title, .todo)
        let after = LineSplicer.splice(metas: before, text: "T\nA", location: 3, length: 0, replacement: "\nB\nC")
        XCTAssertEqual(kinds(after), [.title, .todo, .todo, .todo])
        XCTAssertEqual(after[1], before[1])
    }

    func testOutOfRangeEditIsClamped() {
        let before = metas(.title, .todo)
        let after = LineSplicer.splice(metas: before, text: "T\nA", location: 99, length: 5, replacement: "\n")
        XCTAssertEqual(kinds(after), [.title, .todo, .todo])
    }

    func testCyrillicOffsetsAreUTF16() {
        let before = metas(.title, .todo)
        let text = "План\nСозвон"
        // End of text in UTF-16 units.
        let after = LineSplicer.splice(metas: before, text: text, location: text.utf16.count, length: 0, replacement: "\n")
        XCTAssertEqual(kinds(after), [.title, .todo, .todo])
    }
}
