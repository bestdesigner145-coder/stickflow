// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

@testable import StickflowCore
import XCTest

final class StructuringTests: XCTestCase {
    private struct Fixture: Decodable {
        let input: String
        let plan: NotePlan
    }

    private func fixtures() throws -> [Fixture] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rules", withExtension: "json", subdirectory: "StructuringFixtures"))
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }

    // MARK: The golden set (spec 8.6)

    func testRulesGiveTheExpectedPlanForEveryFixture() throws {
        let all = try fixtures()
        XCTAssertGreaterThanOrEqual(all.count, 20)
        for fixture in all {
            XCTAssertEqual(RuleStructurer.plan(from: fixture.input), fixture.plan, fixture.input)
        }
    }

    func testRulesMeetTheBarOnTheGoldenSet() throws {
        var score = StructuringScore()
        for fixture in try fixtures() {
            let plan = RuleStructurer.plan(from: fixture.input)
            XCTAssertEqual(plan, plan.normalized(), "the rules give a plan that is already within the limits")
            score.record(input: fixture.input, expected: fixture.plan, plan: plan.isEmpty ? nil : plan, seconds: 0)
        }
        XCTAssertEqual(score.answeredShare, 1)
        XCTAssertEqual(score.countMatchShare, 1)
        XCTAssertGreaterThan(score.mustKeep, 20)
        // Spec 14, stage 3: names, numbers and times are kept in at least 95 % of cases.
        XCTAssertGreaterThanOrEqual(score.keptShare, 0.95, "kept \(score.kept) of \(score.mustKeep)")
        XCTAssertLessThanOrEqual(score.wordsPerItem, 5, "an item is five words long at most on average")
    }

    func testMetrics() {
        XCTAssertEqual(
            StructuringMetrics.mustKeep(in: "Потом в 11 созвон с Петей. Отправить 250 тысяч Олегу в 18.30, версия 2.1.3"),
            ["11", "Петей", "250", "Олегу", "18.30", "2.1.3"]
        )
        let plan = NotePlan(title: "План", sections: [
            NotePlan.Section(heading: "Олегу", items: [NotePlan.Item(text: "Созвониться с Петей", time: "11:00", children: ["в 18:30"])]),
        ])
        XCTAssertEqual(StructuringMetrics.kept(["11", "Петей", "250", "Олегу", "18.30", "2.1.3"], in: plan), 4)
        let evening = NotePlan(title: "", sections: [NotePlan.Section(items: [NotePlan.Item(text: "Спортзал", time: "20:00")])])
        XCTAssertEqual(StructuringMetrics.kept(["8", "9", "30"], in: evening), 1, "«в 8 вечера» is kept as 20:00")
        let midnight = NotePlan(title: "", sections: [NotePlan.Section(items: [NotePlan.Item(text: "Пост", time: "00:00")])])
        XCTAssertEqual(StructuringMetrics.kept(["12"], in: midnight), 1)

        var score = StructuringScore()
        XCTAssertEqual(score.keptShare, 1)
        XCTAssertEqual(score.answeredShare, 0)
        XCTAssertEqual(score.latency(percentile: 0.5), 0)
        XCTAssertEqual(score.wordsPerItem, 0)
        let expected = NotePlan(title: "", sections: [NotePlan.Section(items: [NotePlan.Item(text: "a")])])
        score.record(input: "Созвон с Петей в 11", expected: expected, plan: plan, seconds: 2)
        score.record(input: "Купить молоко", expected: expected, plan: nil, seconds: 9)
        score.record(input: "Купить 3 пакета", expected: expected, plan: NotePlan(title: "", sections: []), seconds: 1)
        XCTAssertEqual(score.cases, 3)
        XCTAssertEqual(score.answered, 2)
        XCTAssertEqual(score.countMatches, 1)
        XCTAssertEqual(score.mustKeep, 3)
        XCTAssertEqual(score.kept, 2)
        XCTAssertEqual(score.wordsPerItem, 3)
        XCTAssertEqual(score.latency(percentile: 0.5), 2)
        XCTAssertEqual(score.latency(percentile: 0.95), 9)
        XCTAssertEqual(score.countMatchShare, 1.0 / 3, accuracy: 0.0001)
    }

    // MARK: The rules one by one

    func testDictationFromTheSpec() {
        let plan = RuleStructurer.plan(from: "Короче, сначала надо доделать экран кошелька, там типа пустые состояния и ошибки, "
            + "потом созвон с разработкой в три, и если успею, условно, пост в телегу написать")
        XCTAssertEqual(plan, NotePlan(title: "План на сегодня", sections: [
            NotePlan.Section(heading: nil, items: [
                NotePlan.Item(text: "Доделать экран кошелька", children: ["пустые состояния", "ошибки"]),
                NotePlan.Item(text: "Созвониться с разработкой в три"),
            ]),
            NotePlan.Section(heading: "Если успею", items: [NotePlan.Item(text: "Написать пост в телегу")]),
        ]))
    }

    func testAmbiguousHoursStayAsTheyWereSaid() async throws {
        func time(_ text: String, guessing: Bool = false) -> String? {
            RuleStructurer.extractTime(from: RuleStructurer.tokenize(text), assumesAfternoon: guessing).time
        }
        // An hour from 1 to 7 may be morning or evening: no guess by default.
        XCTAssertNil(time("созвон в три"))
        XCTAssertNil(time("заехать в семь"))
        XCTAssertNil(time("показать в час"))
        XCTAssertNil(time("call at 3"))
        XCTAssertEqual(time("в 7 утра"), "07:00")
        XCTAssertEqual(time("в семь вечера"), "19:00")
        XCTAssertEqual(time("в 8"), "08:00")
        XCTAssertEqual(time("в 15"), "15:00")
        // The spec's reading is still there for whoever wants it.
        XCTAssertEqual(time("созвон в три", guessing: true), "15:00")
        XCTAssertEqual(time("заехать в семь", guessing: true), "19:00")
        XCTAssertEqual(time("показать в час", guessing: true), "13:00")
        var request = StructureRequest(text: "Созвон с разработкой в три")
        var plan = try await RuleStructurer().structure(request)
        XCTAssertEqual(plan.items, [NotePlan.Item(text: "Созвониться с разработкой в три")])
        request.ambiguousHoursAreAfternoon = true
        plan = try await RuleStructurer().structure(request)
        XCTAssertEqual(plan.items, [NotePlan.Item(text: "Созвониться с разработкой", time: "15:00")])
    }

    func testTimes() {
        func time(_ text: String) -> String? {
            RuleStructurer.extractTime(from: RuleStructurer.tokenize(text)).time
        }
        XCTAssertEqual(time("в 11 созвон"), "11:00")
        XCTAssertEqual(time("встреча в 14:30"), "14:30")
        XCTAssertEqual(time("забрать в 18.30"), "18:30")
        XCTAssertEqual(time("в 9 утра"), "09:00")
        XCTAssertEqual(time("в 4 часа дня"), "16:00")
        XCTAssertEqual(time("в 8 вечера"), "20:00")
        XCTAssertEqual(time("в 12 ночи"), "00:00")
        XCTAssertEqual(time("в полдень обед"), "12:00")
        XCTAssertEqual(time("call at 3 pm"), "15:00")
        XCTAssertEqual(time("созвон 16:45"), "16:45")
        XCTAssertNil(time("переписать в 2 раза короче"))
        XCTAssertNil(time("отправить до 18:00"), "a deadline stays in the text")
        XCTAssertNil(time("встреча 15.11 с подрядчиком"), "a date is not a time")
        XCTAssertNil(time("в 25 местах"))
        XCTAssertNil(time("поехать в Самару"))
        XCTAssertEqual(RuleStructurer.extractTime(from: ["созвон", "в", "15", "с", "Петей"]).rest, ["созвон", "с", "Петей"])
    }

    func testInfinitives() {
        for verb in ["сделать", "Написать", "созвониться", "найти", "помочь", "принести", "есть", "лечь", "беречься"] {
            XCTAssertTrue(RuleStructurer.isInfinitive(verb), verb)
        }
        for other in ["пять", "новость", "часть", "ночь", "двадцать", "пути", "почти", "новости", "макеты", "deploy", "ть", "область"] {
            XCTAssertFalse(RuleStructurer.isInfinitive(other), other)
        }
    }

    func testWordsAndPunctuation() {
        XCTAssertEqual(
            RuleStructurer.tokenize("Версия 2.1.3, в 15:30 «релиз».\r\nДальше — тест"),
            ["Версия", "2.1.3", ",", "в", "15:30", "релиз", ".", "\n", "Дальше", "—", "тест"]
        )
        XCTAssertTrue(RuleStructurer.isRussian("Ёлка"))
        XCTAssertFalse(RuleStructurer.isRussian("Tree 42"))
    }

    func testFillersOnlyGiveNothing() async {
        XCTAssertTrue(RuleStructurer.plan(from: "ну типа короче").isEmpty)
        XCTAssertTrue(RuleStructurer.plan(from: "").isEmpty)
        let rules = RuleStructurer()
        do {
            _ = try await rules.structure(StructureRequest(text: "ну, в общем, как бы"))
            XCTFail("there is nothing to do in fillers")
        } catch {
            XCTAssertEqual(error as? StructurerError, .nothingToDo)
        }
    }

    func testStructurerInterface() async throws {
        let rules = RuleStructurer()
        XCTAssertEqual(rules.id, "rules")
        XCTAssertTrue(rules.isLocal)
        XCTAssertFalse(rules.displayName.isEmpty)
        let health = await rules.health()
        XCTAssertEqual(health, .ready)
        let request = StructureRequest(text: "Write the report, then call Anna at 11", locale: Locale(identifier: "en"))
        let plan = try await rules.structure(request)
        XCTAssertEqual(plan.title, "Plan for today")
        XCTAssertEqual(plan.items.map(\.text), ["Write the report", "Call Anna"])
        XCTAssertEqual(plan.items.map(\.time), [nil, "11:00"])
        if case .new = request.mode {} else { XCTFail("a request is for a new note by default") }
        XCTAssertEqual(request.rules, "")
    }

    // MARK: The plan

    func testNormalizeCleansAModelsAnswer() {
        let long = String(repeating: "слово ", count: 30)
        let raw = NotePlan(title: "  План  ", sections: [
            NotePlan.Section(heading: "  ", items: [
                NotePlan.Item(text: "  Купить молоко ", time: "9:00", children: [" жирное ", "", "a", "b", "c", "d", "e", "f"]),
                NotePlan.Item(text: "   "),
                NotePlan.Item(text: long, task: false, time: " 15:00 "),
            ]),
            NotePlan.Section(heading: "Пусто", items: [NotePlan.Item(text: "")]),
        ])
        let plan = raw.normalized()
        XCTAssertEqual(plan.title, "План")
        XCTAssertEqual(plan.sections.count, 1)
        XCTAssertNil(plan.sections[0].heading)
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertEqual(plan.items[0], NotePlan.Item(text: "Купить молоко", children: ["жирное", "a", "b", "c", "d", "e"]))
        XCTAssertEqual(plan.items[1].time, "15:00")
        XCTAssertLessThanOrEqual(plan.items[1].text.count, NotePlan.Limit.item)
        XCTAssertTrue(plan.items[1].text.hasSuffix("…"))
        XCTAssertFalse(plan.items[1].text.hasSuffix(" …"))
        XCTAssertFalse(plan.isEmpty)
        XCTAssertTrue(NotePlan(title: "x", sections: []).isEmpty)
    }

    func testClocks() {
        XCTAssertTrue(NotePlan.isClock("09:30"))
        XCTAssertTrue(NotePlan.isClock("23:59"))
        for bad in ["9:30", "24:00", "12:60", "12-30", "ab:cd", "12:3", ""] {
            XCTAssertFalse(NotePlan.isClock(bad), bad)
        }
        XCTAssertEqual(NotePlan.clip("коротко", to: 40), "коротко")
        XCTAssertEqual(NotePlan.clip("Оченьдлинноесловобезпробелов", to: 10), "Оченьдлин…")
        XCTAssertEqual(NotePlan.clip("Первое, второе третье", to: 16), "Первое, второе…")
    }

    func testPlanBecomesBlocks() {
        let plan = NotePlan(title: "План", sections: [
            NotePlan.Section(heading: nil, items: [NotePlan.Item(text: "Созвониться с Петей", time: "11:00")]),
            NotePlan.Section(heading: "Кошелёк", items: [
                NotePlan.Item(text: "Доделать экран", children: ["пустые состояния"]),
                NotePlan.Item(text: "Заметка", task: false),
            ]),
        ])
        let blocks = plan.blocks()
        XCTAssertEqual(blocks.map(\.kind), [.todo, .heading2, .todo, .bullet, .bullet])
        XCTAssertEqual(blocks.map(\.text), ["Созвониться с Петей — 11:00", "Кошелёк", "Доделать экран", "пустые состояния", "Заметка"])
        XCTAssertEqual(blocks.map(\.indent), [0, 0, 0, 1, 0])
    }

    func testAddingToAStickerPutsItemsWhereTheyBelong() {
        let sticker = [
            Block(kind: .todo, text: "Проверить почту"),
            Block(kind: .heading2, text: "Кошелёк"),
            Block(kind: .todo, text: "Доделать экран"),
            Block(kind: .bullet, text: "ошибки", indent: 1),
            Block(kind: .heading2, text: "Если успею"),
            Block(kind: .todo, text: "Написать пост"),
        ]
        let plan = NotePlan(title: "Не важно", sections: [
            NotePlan.Section(items: [NotePlan.Item(text: "Позвонить маме"), NotePlan.Item(text: "проверить ПОЧТУ")]),
            NotePlan.Section(heading: "кошелёк", items: [NotePlan.Item(text: "Отдать в разработку", time: "15:00", children: ["макеты"])]),
            NotePlan.Section(heading: "Дом", items: [NotePlan.Item(text: "Помыть окна", task: false)]),
            NotePlan.Section(heading: "Если успею", items: [NotePlan.Item(text: "Написать пост")]),
        ])
        let result = PlanAppender.append(plan, to: sticker)
        XCTAssertEqual(result.blocks.map(\.text), [
            "Проверить почту", "Позвонить маме",
            "Кошелёк", "Доделать экран", "ошибки", "Отдать в разработку — 15:00", "макеты",
            "Если успею", "Написать пост",
            "Дом", "Помыть окна",
        ])
        XCTAssertEqual(result.added, [1, 5, 6, 9, 10])
        XCTAssertEqual(result.blocks[6].indent, 1)
        XCTAssertEqual(result.blocks[9].kind, .heading2)
        XCTAssertEqual(result.blocks[10].kind, .bullet)
        XCTAssertEqual(Array(result.blocks.prefix(1)), Array(sticker.prefix(1)), "what was there is untouched")

        // Nothing new: nothing changes. An empty sticker simply takes the plan.
        let again = PlanAppender.append(plan, to: result.blocks)
        XCTAssertEqual(again.blocks, result.blocks)
        XCTAssertTrue(again.added.isEmpty)
        let fresh = PlanAppender.append(NotePlan(title: "", sections: [NotePlan.Section(items: [NotePlan.Item(text: "Одно")])]), to: [])
        XCTAssertEqual(fresh.blocks.map(\.text), ["Одно"])
        XCTAssertEqual(fresh.added, [0])
    }

    func testPlanAsPreviewLines() {
        let plan = NotePlan(title: "План", sections: [
            NotePlan.Section(items: [NotePlan.Item(text: "Созвониться", time: "11:00", children: ["с Петей"])]),
            NotePlan.Section(heading: "Дом", items: [NotePlan.Item(text: "Заметка", task: false)]),
        ])
        XCTAssertEqual(plan.previewLines(), ["План", "☐ Созвониться — 11:00", "    • с Петей", "ДОМ", "• Заметка"])
        XCTAssertEqual(plan.previewLines(includingTitle: false).first, "☐ Созвониться — 11:00")
    }

    func testPlanReadsAModelsJSON() throws {
        let json = """
        {"title":"План на день","sections":[
         {"heading":"Кошелёк","items":[{"text":"Доделать экран","task":true,"time":null,"children":["ошибки"]}]},
         {"heading":null,"items":[{"text":"Заметка","task":false}]}]}
        """
        let plan = try JSONDecoder().decode(NotePlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.sections[0].items[0], NotePlan.Item(text: "Доделать экран", children: ["ошибки"]))
        XCTAssertEqual(plan.sections[1], NotePlan.Section(items: [NotePlan.Item(text: "Заметка", task: false)]))
        let again = try JSONDecoder().decode(NotePlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(again, plan)
    }
}
