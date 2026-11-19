// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

@testable import StickflowCore
import XCTest

/// Structuring by meaning (spec 18.2–18.3): the cleaning after an answer and
/// the scoring of grouping, repeats and junk.
final class SemanticTests: XCTestCase {
    private func cases() throws -> [SemanticCase] {
        let found = Bundle.module.url(forResource: "semantic", withExtension: "json", subdirectory: "StructuringFixtures")
        let url = try XCTUnwrap(found)
        return try JSONDecoder().decode([SemanticCase].self, from: Data(contentsOf: url))
    }

    private func flat(_ title: String, _ items: [String]) -> NotePlan {
        plan(title, [(nil, items)])
    }

    private func plan(_ title: String, _ sections: [(String?, [String])]) -> NotePlan {
        NotePlan(title: title, sections: sections.map { heading, items in
            NotePlan.Section(heading: heading, items: items.map { NotePlan.Item(text: $0) })
        })
    }

    // MARK: Cleaning

    func testWordsAndStems() {
        XCTAssertEqual(PlanCleaner.words(of: "Ещё раз-два, «Карту»!"), ["еще", "раз", "два", "карту"])
        XCTAssertEqual(PlanCleaner.stems(of: "Карту, карта и в карты"), ["карт"])
        let said = PlanCleaner.stems(of: "Внести правки в виртуальную карту")
        XCTAssertEqual(said, PlanCleaner.stems(of: "внести правку в виртуальной карте"))
        XCTAssertNotEqual(PlanCleaner.stems(of: "Выкатить версию 2.1"), PlanCleaner.stems(of: "Выкатить версию 2.2"))
        XCTAssertEqual(PlanCleaner.stem("кот"), "кот")
        XCTAssertTrue(PlanCleaner.stems(of: "и в на").isEmpty)
    }

    /// The sticker the author got on 16.11.2026 (stage 3 review, H2).
    func testARepeatedItemAndAGreetingAreTakenOut() {
        let sticker = flat("План на сегодня", [
            "Привет",
            "Внести правки в виртуальную карту, чтобы меня слышно вообще",
            "Внести правки в виртуальную карту",
            "Заменить иконку на главном экране",
        ])
        let (cleaned, merged) = PlanCleaner.clean(sticker)
        XCTAssertEqual(cleaned.items.map(\.text), [
            "Внести правки в виртуальную карту, чтобы меня слышно вообще",
            "Заменить иконку на главном экране",
        ])
        XCTAssertEqual(merged, 1)
        XCTAssertEqual(sticker.cleaned(), cleaned)
        XCTAssertEqual(cleaned.cleaned(), cleaned, "a clean plan stays as it is")
    }

    func testTheMoreExactWordingStaysInTheFirstPlace() {
        let both = plan("План", [("Дом", ["Купить молоко", "Помыть окна"]), ("Ещё", ["Купить молоко и хлеб"])])
        let cleaned = both.cleaned()
        XCTAssertEqual(cleaned.sections.count, 1, "a section left empty goes away")
        XCTAssertEqual(cleaned.items.map(\.text), ["Купить молоко и хлеб", "Помыть окна"])

        let apart = plan("План", [(nil, ["Купить молоко", "Купить хлеб", "Написать Саше про релиз", "Написать Маше про релиз"])])
        XCTAssertEqual(apart.cleaned(), apart, "different things stay different")
    }

    func testTimesChildrenAndTaskFlagsOfMergedItems() {
        let twice = [NotePlan.Item(text: "Созвониться с Петей", time: "11:00"), NotePlan.Item(text: "Созвониться с Петей", time: "15:00")]
        var calls = NotePlan(title: "План", sections: [NotePlan.Section(items: twice)])
        XCTAssertEqual(calls.cleaned(), calls, "two times are two calls")
        calls.sections[0].items[0].time = nil
        calls.sections[0].items[0].task = false
        calls.sections[0].items[0].children = ["про релиз"]
        calls.sections[0].items[1].children = ["Про релиз", "позвать Катю", "созвониться"]
        let merged = calls.cleaned()
        XCTAssertEqual(merged.items, [
            NotePlan.Item(text: "Созвониться с Петей", task: true, time: "15:00", children: ["про релиз", "позвать Катю"]),
        ])
    }

    func testGreetings() {
        let hello = plan("План", [(nil, ["Добрый день", "Привет всем", "Hello", "Привет Пете передать"])])
        XCTAssertEqual(hello.cleaned().items.map(\.text), ["Привет Пете передать"])
        let timed = NotePlan(title: "", sections: [NotePlan.Section(items: [NotePlan.Item(text: "Привет", time: "10:00")])])
        XCTAssertEqual(timed.cleaned().items.count, 1, "a greeting with a time was meant")
        XCTAssertTrue(plan("", [(nil, ["Привет"])]).cleaned().isEmpty)
    }

    func testTheRulesCleanToo() async throws {
        let said = "Привет. Купить молоко. Купить молоко"
        XCTAssertEqual(RuleStructurer.plan(from: said).items.count, 3)
        let cleaned = try await RuleStructurer().structure(StructureRequest(text: said))
        XCTAssertEqual(cleaned.items.map(\.text), ["Купить молоко"])
        do {
            _ = try await RuleStructurer().structure(StructureRequest(text: "Привет"))
            XCTFail("a greeting alone is nothing to do")
        } catch {
            XCTAssertEqual(error as? StructurerError, .nothingToDo)
        }
    }

    // MARK: The set

    func testTheSetIsSound() throws {
        let all = try cases()
        XCTAssertGreaterThanOrEqual(all.count, 15)
        XCTAssertTrue(all[0].input.contains("виртуальную карту"), "the author's phrase of 16.11.2026 leads the set")
        for semantic in all {
            XCTAssertFalse(semantic.input.isEmpty)
            let needles = semantic.groups.flatMap(\.items).flatMap { $0 } + semantic.optional.flatMap { $0 } + semantic.junk
            for needle in needles {
                XCTAssertEqual(needle, SemanticCase.fold(needle), "needles are written folded: \(needle)")
            }
            // Only the two regressions of spec 18.9 are both in the set and in the prompt, and they say so.
            XCTAssertEqual(semantic.inPrompt, StructurePrompt.examples.contains { $0.said == semantic.input }, semantic.input)
            // The rules run through every phrase without giving up on the form.
            let plan = RuleStructurer.plan(from: semantic.input)
            XCTAssertEqual(plan, plan.normalized())
            _ = semantic.verdict(for: plan.cleaned())
        }
        XCTAssertEqual(all.filter(\.groups.isEmpty).count, 1)
        XCTAssertTrue(all.contains { !$0.scoresGrouping })
    }

    // MARK: Scoring

    func testVerdictOnTheAuthorsPhrase() throws {
        let card = try XCTUnwrap(cases().first)
        let sticker = flat("План на сегодня", [
            "Привет", "Внести правки в виртуальную карту, чтобы меня слышно вообще", "Внести правки в виртуальную карту",
            "Заменить иконку на главном экране", "Проверить лимиты",
        ]).cleaned()
        var verdict = card.verdict(for: sticker)
        XCTAssertEqual([verdict.expected, verdict.found, verdict.extra, verdict.junk], [2, 2, 0, 1])
        XCTAssertTrue(verdict.grouped, "one topic needs no section of its own")
        XCTAssertEqual(verdict.titled, false, "but the title must name it")

        verdict = card.verdict(for: plan("Виртуальная карта", [(nil, ["Заменить иконку на главном экране", "Проверить лимиты"])]))
        XCTAssertEqual([verdict.found, verdict.extra, verdict.junk], [2, 0, 0])
        XCTAssertTrue(verdict.grouped, "one topic may be the title")

        let parent = NotePlan.Item(text: "Внести правки", children: ["заменить иконку", "проверить лимиты"])
        let nested = NotePlan(title: "План", sections: [NotePlan.Section(heading: "Виртуальная карта", items: [parent])])
        verdict = card.verdict(for: nested)
        XCTAssertEqual([verdict.found, verdict.extra], [2, 0], "things said as details count, the optional item is not extra")
        XCTAssertTrue(verdict.grouped)
    }

    func testVerdictOnThreeGroups() throws {
        let three = try XCTUnwrap(cases().first { $0.input.hasPrefix("Нужно обновить иконки") })
        let right = plan("План на сегодня", [
            ("Дизайн-система", ["Обновить иконки", "Поправить тени у карточек"]),
            ("Лендинг", ["Написать текст первого экрана", "Подобрать фото"]),
            ("Личное", ["Записаться к стоматологу"]),
        ])
        XCTAssertEqual(three.verdict(for: right), SemanticCase.Verdict(expected: 5, found: 5, extra: 0, junk: 0, grouped: true))

        let flat = plan("План на сегодня", [(nil, right.items.map(\.text))])
        XCTAssertEqual(three.verdict(for: flat), SemanticCase.Verdict(expected: 5, found: 5, extra: 0, junk: 0, grouped: false))

        let lost = plan("План", [("Дизайн-система", ["Обновить иконки"]), ("Лендинг", ["Написать текст", "Подобрать фото", "Выпить кофе"])])
        XCTAssertEqual(three.verdict(for: lost), SemanticCase.Verdict(expected: 5, found: 3, extra: 1, junk: 0, grouped: false))

        let misnamed = plan("План", [
            ("Работа", ["Обновить иконки", "Поправить тени"]), ("Лендинг", ["Написать текст", "Подобрать фото"]),
            (nil, ["Записаться к стоматологу"]),
        ])
        XCTAssertFalse(three.verdict(for: misnamed).grouped, "the section must carry the topic's name")

        let split = plan("План", [
            ("Дизайн-система", ["Обновить иконки"]), ("Дизайн-система, тени", ["Поправить тени"]),
            ("Лендинг", ["Написать текст", "Подобрать фото"]), (nil, ["Записаться к стоматологу"]),
        ])
        XCTAssertFalse(three.verdict(for: split).grouped, "one topic in two sections is not a group")
    }

    func testScore() throws {
        let all = try cases()
        let nothing = try XCTUnwrap(all.first(where: \.groups.isEmpty))
        var score = SemanticScore()
        XCTAssertEqual(score.answeredShare, 0)
        XCTAssertEqual(score.groupedShare, 0)
        XCTAssertEqual(score.foundShare, 0)
        XCTAssertEqual(score.keptShare, 1)
        XCTAssertEqual(score.wordsPerItem, 0)
        XCTAssertEqual(score.latency(percentile: 0.5), 0)

        // Nothing to do, and the structurer says so.
        score.record(nothing, raw: nil, failed: false, seconds: 1)
        XCTAssertEqual([score.cases, score.answered, score.grouped], [1, 1, 1])
        // Nothing to do, and the request failed.
        score.record(nothing, raw: nil, failed: true, seconds: 2)
        XCTAssertEqual([score.cases, score.answered, score.grouped], [2, 1, 1])
        // Nothing to do, and a task was made of the microphone check.
        score.record(nothing, raw: plan("План", [(nil, ["Проверка связи"])]), failed: false, seconds: 3)
        XCTAssertEqual([score.answered, score.grouped, score.extra, score.junk], [2, 1, 1, 1])
        // Only a greeting came back: the cleaning leaves nothing, which is right.
        score.record(nothing, raw: plan("План", [(nil, ["Привет"])]), failed: false, seconds: 3)
        XCTAssertEqual([score.answered, score.grouped, score.extra], [3, 2, 1])

        let card = all[0]
        let repeated = flat("Виртуальная карта", ["Заменить иконку на главном экране", "Заменить иконку", "Проверить лимиты"])
        score.record(card, raw: repeated, failed: false, seconds: 5)
        XCTAssertEqual([score.cases, score.answered, score.grouped, score.groupingCases], [5, 4, 3, 5])
        XCTAssertEqual([score.expected, score.found, score.duplicates], [2, 2, 1])
        XCTAssertEqual(score.items, 3, "the item of the microphone check and the two of the card")
        XCTAssertEqual(score.foundShare, 1)
        XCTAssertEqual(score.groupedShare, 0.6)
        XCTAssertEqual(score.answeredShare, 0.8)
        XCTAssertEqual(score.latency(percentile: 1), 5)
        XCTAssertGreaterThan(score.wordsPerItem, 1)

        // A phrase whose grouping is anyone's guess is not counted for grouping.
        let free = try XCTUnwrap(all.first { !$0.scoresGrouping })
        score.record(free, raw: nil, failed: true, seconds: 1)
        XCTAssertEqual(score.groupingCases, 5)
        XCTAssertGreaterThan(score.mustKeep, 3, "Петей, 2.1.3, 14:30, Кате, Олегу, 250")
        XCTAssertEqual(score.kept, 0)
        XCTAssertEqual(score.keptShare, 0)
    }

    func testCaseReadsItsDefaults() throws {
        let json = #"{"input":"Купить молоко","groups":[{"items":[["молок"]]}]}"#
        let semantic = try JSONDecoder().decode(SemanticCase.self, from: Data(json.utf8))
        XCTAssertEqual(semantic, SemanticCase(input: "Купить молоко", groups: [SemanticCase.Group(items: [["молок"]])]))
        XCTAssertTrue(semantic.scoresGrouping)
        XCTAssertTrue(SemanticCase.has(["мол|хлеб", "куп"], in: "купить хлеб"))
        XCTAssertFalse(SemanticCase.has(["мол|хлеб", "куп"], in: "съесть хлеб"))
    }
}
