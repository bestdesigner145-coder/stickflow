// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

@testable import StickflowCore
import XCTest

/// What the built-in model is given (spec 18.9–18.10): the prompt in its
/// family's format, the grammar of the answer, a title of its own.
final class LocalModelPromptTests: XCTestCase {
    private let turns = [
        ChatMessage(role: .system, content: "Правила"),
        ChatMessage(role: .user, content: "Пример"),
        ChatMessage(role: .assistant, content: "{}"),
        ChatMessage(role: .user, content: "Купить молоко"),
    ]

    func testChatML() {
        let qwen = PromptFormat.chatML(thinkingOff: true).render(turns)
        XCTAssertEqual(qwen, """
        <|im_start|>system
        Правила<|im_end|>
        <|im_start|>user
        Пример<|im_end|>
        <|im_start|>assistant
        {}<|im_end|>
        <|im_start|>user
        Купить молоко<|im_end|>
        <|im_start|>assistant
        <think>

        </think>


        """)
        XCTAssertTrue(PromptFormat.chatML(thinkingOff: false).render(turns).hasSuffix("<|im_start|>assistant\n"))
    }

    func testGemmaFoldsTheSystemTurnIntoTheFirstUserTurn() {
        let gemma = PromptFormat.gemma.render(turns)
        XCTAssertEqual(gemma, """
        <bos><start_of_turn>user
        Правила

        Пример<end_of_turn>
        <start_of_turn>model
        {}<end_of_turn>
        <start_of_turn>user
        Купить молоко<end_of_turn>
        <start_of_turn>model

        """)
    }

    func testFamilyComesFromTheModelsTemplate() {
        XCTAssertEqual(PromptFormat.detect(template: "{% for m in messages %}<start_of_turn>{{ m.role }}"), .gemma)
        let qwen3 = "<|im_start|>{{ role }} {% if enable_thinking %}<think>{% endif %}"
        XCTAssertEqual(PromptFormat.detect(template: qwen3), .chatML(thinkingOff: true))
        XCTAssertEqual(PromptFormat.detect(template: "<|im_start|>{{ role }}"), .chatML(thinkingOff: false))
        XCTAssertNil(PromptFormat.detect(template: "[INST]"))
        XCTAssertNil(PromptFormat.detect(template: nil))
    }

    func testGrammarNamesEveryRuleItUses() {
        let grammar = PlanGrammar.gbnf
        var defined: Set<String> = []
        var used: Set<String> = []
        for line in grammar.split(separator: "\n") {
            let parts = line.components(separatedBy: " ::= ")
            XCTAssertEqual(parts.count, 2, String(line))
            defined.insert(parts[0])
            // Names outside quotes and brackets are references to rules.
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
        XCTAssertTrue(grammar.contains(#""\"children\"""#))
    }

    func testTakenTitlesGoIntoTheLastTurnOnly() {
        var request = StructureRequest(text: "Купить молоко")
        let plain = StructurePrompt.messages(for: request)
        request.takenTitles = ["План на сегодня", " ", "UX Feedback"]
        let asked = StructurePrompt.messages(for: request)
        XCTAssertEqual(Array(asked.dropLast()), Array(plain.dropLast()), "the turns before the text stay the same")
        XCTAssertEqual(asked.last?.content, "Заголовки, которые уже есть на экране: «План на сегодня», «UX Feedback». "
            + "Возьми другой.\n\nДиктовка: Купить молоко")
    }

    func testTheRegressionsAreAmongTheExamples() {
        let said = StructurePrompt.examples.map(\.said)
        XCTAssertEqual(said.count, 5)
        XCTAssertTrue(said.contains(StructurePrompt.uxFeedbackPhrase))
        XCTAssertTrue(said.contains(StructurePrompt.virtualCardPhrase))
        for example in StructurePrompt.examples {
            XCTAssertNoThrow(try PlanParser.parse(example.answer), example.said)
            XCTAssertFalse(example.answer.contains("\"15:00\""), "spec 18.9: «в три» is not 15:00")
        }
        let ux = try? PlanParser.parse(StructurePrompt.examples[3].answer)
        XCTAssertEqual(ux?.title, "UX Feedback")
        XCTAssertEqual(ux?.items.count, 3)
    }

    func testTitleApartFromTheStickersOnScreen() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 14, minute: 5)))
        let plan = NotePlan(title: "План на сегодня", sections: [NotePlan.Section(items: [NotePlan.Item(text: "Купить хлеб")])])
        XCTAssertEqual(plan.titled(apartFrom: ["UX Feedback"], at: now, calendar: calendar), plan)
        XCTAssertEqual(plan.titled(apartFrom: ["план на сегодня "], at: now, calendar: calendar).title, "План на сегодня, 14:05")
        let twice = plan.titled(apartFrom: ["План на сегодня", "План на сегодня, 14:05"], at: now, calendar: calendar)
        XCTAssertEqual(twice.title, "План на сегодня, 14:05 (2)")
        var long = plan
        long.title = String(repeating: "Д", count: 40)
        XCTAssertLessThanOrEqual(long.titled(apartFrom: [long.title], at: now, calendar: calendar).title.count, NotePlan.Limit.title)
    }

    func testOrderAndTitleOfTheUXFeedbackPhrase() throws {
        let found = Bundle.module.url(forResource: "semantic", withExtension: "json", subdirectory: "StructuringFixtures")
        let all = try JSONDecoder().decode([SemanticCase].self, from: Data(contentsOf: XCTUnwrap(found)))
        let ux = try XCTUnwrap(all.first { $0.input == StructurePrompt.uxFeedbackPhrase })
        XCTAssertTrue(ux.inPrompt)
        let right = try PlanParser.parse(StructurePrompt.examples[3].answer)
        var verdict = ux.verdict(for: right)
        XCTAssertEqual(verdict, SemanticCase.Verdict(expected: 3, found: 3, extra: 0, junk: 0, grouped: true, titled: true))

        // The order in which it was said is not the order in which it is done.
        let asSaid = [
            "Написать вопросы для UX-фидбека", "Выписать гипотезы", "Изучить методы на сайте",
            "Провести исследование через сервис UX Feedback, грубо говоря",
        ]
        let said = NotePlan(title: "План на сегодня", sections: [NotePlan.Section(items: asSaid.map { NotePlan.Item(text: $0) })])
        verdict = ux.verdict(for: said)
        XCTAssertEqual(verdict, SemanticCase.Verdict(expected: 3, found: 3, extra: 1, junk: 1, grouped: false, titled: false))
    }
}
