// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

@testable import StickflowCore
import XCTest

/// Voice commands for a sticker (spec 18.22): the sticker as the model sees it,
/// the answer, and what each operation does to the lines.
final class StickerEditTests: XCTestCase {
    private let blocks = [
        Block(kind: .todo, text: "Доделать калькулятор"),
        Block(kind: .todo, text: "Созвон с разработкой 15:00"),
        Block(kind: .bullet, text: "Посмотреть макеты экрана лимита"),
        Block(kind: .bullet, text: "только тёмная тема", indent: 1),
        Block(kind: .todo, text: "Написать пост про запуск"),
    ]

    private func apply(_ json: String) throws -> StickerEdit.Result {
        try StickerEdit.parse(json).apply(title: "Мультизайм", to: blocks)
    }

    private func texts(_ result: StickerEdit.Result) -> [String] {
        result.blocks.map { block in
            let mark = switch block.kind {
            case .todo: block.done ? "[x] " : "[ ] "
            case .bullet: "- "
            case .heading2: "## "
            case .text: ""
            }
            return String(repeating: "  ", count: block.indent) + mark + block.text
        }
    }

    func testTheModelSeesNumberedLines() {
        let shown = StickerEdit.numberedLines(title: "Мультизайм", blocks: blocks)
        XCTAssertEqual(shown, """
        Заголовок: Мультизайм
        1. [ ] Доделать калькулятор
        2. [ ] Созвон с разработкой 15:00
        3. - Посмотреть макеты экрана лимита
        4.     - только тёмная тема
        5. [ ] Написать пост про запуск
        """)
    }

    func testAddChildrenGoesUnderTheLineAndItsPoints() throws {
        let result = try apply(#"{"unsure": false, "ops": [{"op": "add_children", "target": 3, "items": ["и светлая тоже"]}]}"#)
        XCTAssertEqual(texts(result)[2...4], ["- Посмотреть макеты экрана лимита", "  - только тёмная тема", "  - и светлая тоже"])
        XCTAssertEqual(result.changed, [result.blocks[4].id])
    }

    func testSetTypeCheckAndUncheck() throws {
        let result = try apply(#"{"ops": [{"op": "set_type", "target": 3, "type": "task"}, {"op": "check", "target": 2}]}"#)
        XCTAssertEqual(texts(result)[1...2], ["[x] Созвон с разработкой 15:00", "[ ] Посмотреть макеты экрана лимита"])
        XCTAssertNotNil(result.blocks[1].doneAt)
        XCTAssertEqual(result.changed, [blocks[1].id, blocks[2].id], "the lines keep their ids")
        let undone = try StickerEdit(operations: [.uncheck(target: 2)]).apply(title: "", to: result.blocks)
        XCTAssertFalse(undone.blocks[1].done)
    }

    func testDeleteTakesThePointsUnderTheLine() throws {
        let result = try apply(#"{"unsure": false, "ops": [{"op": "delete", "target": 3}]}"#)
        XCTAssertEqual(result.blocks.map(\.text), ["Доделать калькулятор", "Созвон с разработкой 15:00", "Написать пост про запуск"])
    }

    func testNumbersMeanTheLinesAsTheModelSawThem() throws {
        // After the first line is deleted, "5" is still the post, not a line that is not there.
        let result = try apply(#"{"unsure": false, "ops": [{"op": "delete", "target": 1}, {"op": "check", "target": 5}]}"#)
        XCTAssertEqual(texts(result).last, "[x] Написать пост про запуск")
    }

    func testMoveToTheTopTakesThePoints() throws {
        let result = try apply(#"{"unsure": false, "ops": [{"op": "move", "target": 3, "position": 1}]}"#)
        XCTAssertEqual(texts(result), [
            "- Посмотреть макеты экрана лимита", "  - только тёмная тема", "[ ] Доделать калькулятор",
            "[ ] Созвон с разработкой 15:00", "[ ] Написать пост про запуск",
        ])
    }

    func testMoveDoesNotLandInsideAnotherLinesPoints() throws {
        // Place 3 is the point under "Посмотреть макеты": the line goes after that point.
        let result = try apply(#"{"unsure": false, "ops": [{"op": "move", "target": 1, "position": 3}]}"#)
        XCTAssertEqual(
            texts(result)[1...3],
            ["- Посмотреть макеты экрана лимита", "  - только тёмная тема", "[ ] Доделать калькулятор"]
        )
    }

    func testRenameAndEditText() throws {
        let result = try apply(
            #"{"ops": [{"op": "rename", "title": "Мультизайм, этап 2"}, "#
                + #"{"op": "edit_text", "target": 1, "text": "Доделать калькулятор лимита"}]}"#
        )
        XCTAssertEqual(result.title, "Мультизайм, этап 2")
        XCTAssertTrue(result.renamed)
        XCTAssertEqual(result.blocks[0].text, "Доделать калькулятор лимита")
    }

    func testPlainDictationIsAppended() throws {
        let json = #"{"ops": [{"op": "add_items", "sections": [{"heading": null, "items": ["#
            + #"{"text": "Согласовать тексты с юристами", "task": true, "time": null, "children": []}, "#
            + #"{"text": "Доделать калькулятор", "task": true, "time": null, "children": []}]}]}]}"#
        let edit = try StickerEdit.parse(json)
        XCTAssertFalse(edit.isCommand)
        let result = try edit.apply(title: "Мультизайм", to: blocks)
        XCTAssertEqual(result.blocks.count, blocks.count + 1, "what the sticker says is not repeated")
        XCTAssertEqual(result.blocks.last?.text, "Согласовать тексты с юристами")
    }

    func testUnsureOrUnknownLineChangesNothing() {
        XCTAssertThrowsError(try apply(#"{"unsure": true, "ops": []}"#)) {
            XCTAssertEqual($0 as? StickerEdit.Failure, .unclearLine)
        }
        XCTAssertThrowsError(try apply(#"{"unsure": false, "ops": [{"op": "check", "target": 1}, {"op": "delete", "target": 9}]}"#)) {
            XCTAssertEqual($0 as? StickerEdit.Failure, .unclearLine, "one wrong line cancels the whole command")
        }
        XCTAssertThrowsError(try apply(#"{"unsure": false, "ops": [{"op": "check", "target": 0}]}"#))
        XCTAssertThrowsError(try apply(#"{"unsure": false, "ops": []}"#)) {
            XCTAssertEqual($0 as? StickerEdit.Failure, .nothing)
        }
    }

    func testAnswersThatAreNotOperationsAreRefused() {
        XCTAssertThrowsError(try StickerEdit.parse("Готово!"))
        XCTAssertThrowsError(try StickerEdit.parse(#"{"unsure": false, "ops": [{"op": "explode", "target": 1}]}"#))
        XCTAssertNoThrow(try StickerEdit.parse("Вот: {\"ops\": [{\"op\": \"check\", \"target\": 2}]} — готово"))
    }

    func testEveryExampleOfThePromptWorksOnItsSticker() throws {
        let lines = StickerEditPrompt.sticker.split(separator: "\n").dropFirst()
        let sticker = lines.map { line -> Block in
            let text = line.split(separator: " ", maxSplits: 1)[1]
            if text.hasPrefix("[ ] ") { return Block(kind: .todo, text: String(text.dropFirst(4))) }
            return Block(kind: .bullet, text: String(text.dropFirst(2)))
        }
        XCTAssertEqual(StickerEdit.numberedLines(title: "Мультизайм", blocks: sticker), StickerEditPrompt.sticker)
        for example in StickerEditPrompt.examples {
            let edit = try StickerEdit.parse(example.answer)
            if edit.unsure { continue }
            XCTAssertNoThrow(try edit.apply(title: "Мультизайм", to: sticker), example.said)
        }
    }

    func testTheLastTurnHoldsTheStickerAndWhatWasSaid() {
        let request = StickerEditRequest(title: "Мультизайм", blocks: blocks, text: "отметь созвон")
        let messages = StickerEditPrompt.messages(for: request)
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertEqual(messages.count, 2 + StickerEditPrompt.examples.count * 2)
        XCTAssertTrue(messages.last?.content.hasSuffix("Сказано: отметь созвон") ?? false)
        XCTAssertTrue(messages.last?.content.contains("2. [ ] Созвон с разработкой 15:00") ?? false)
    }

    func testTheGrammarNamesEveryRuleItUses() {
        let grammar = StickerEditPrompt.grammar
        var defined: Set<String> = []
        var used: Set<String> = []
        for line in grammar.split(separator: "\n") {
            let parts = line.components(separatedBy: " ::= ")
            XCTAssertEqual(parts.count, 2, String(line))
            defined.insert(parts[0])
            var body = parts[1]
            for pattern in [#""(\\.|[^"\\])*""#, #"\[(\\.|[^\]\\])*\]"#, #"\{[0-9,]+\}"#] {
                body = body.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
            }
            for name in body.split(whereSeparator: { !($0.isLetter || $0 == "_") }) {
                used.insert(String(name))
            }
        }
        XCTAssertEqual(used.subtracting(defined), [], "rules used but not defined")
        XCTAssertEqual(defined.subtracting(used), ["root"], "rules defined but never used")
        for name in ["add_items", "add_children", "set_type", "check", "uncheck", "delete", "move", "rename", "edit_text"] {
            XCTAssertTrue(grammar.contains(#""\"\#(name)\"""#), name)
            XCTAssertTrue(StickerEditPrompt.rules.contains(#""\#(name)""#), name)
        }
    }

    func testOnlyAModelEditsStickers() async throws {
        XCTAssertFalse(RuleStructurer().editsStickers)
        let content = #"{"ops": [{"op": "check", "target": 2}]}"#
        let answer = try JSONSerialization.data(withJSONObject: ["message": ["role": "assistant", "content": content]])
        let network = try ScriptedNetwork([(XCTUnwrap(String(bytes: answer, encoding: .utf8)), 200)])
        let ollama = try ChatStructurer(provider: .ollama(host: XCTUnwrap(URL(string: "http://localhost:11434")), model: "qwen3:4b"), network: network)
        XCTAssertTrue(ollama.editsStickers)
        let edit = try await ollama.edit(StickerEditRequest(title: "Мультизайм", blocks: blocks, text: "отметь созвон"))
        XCTAssertEqual(edit.operations, [.check(target: 2)])
        let requests = await network.requests
        let body = try XCTUnwrap(requests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertNil(body["format"], "the plan's schema is not asked for: operations are not a plan")
    }
}
