// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import StickflowCore
import XCTest

final class CallEdgeTests: XCTestCase {
    private let main = ScreenLayout(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805)
    )

    func testFreeRightEdgeIsTheDefault() {
        XCTAssertEqual(CallEdge.choose(for: main, others: []), CallEdge(side: .right, isStrict: false))
    }

    func testDisplayOnTheRightMovesThePadToTheLeft() {
        let right = ScreenLayout(
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        )
        XCTAssertEqual(CallEdge.choose(for: main, others: [right]), CallEdge(side: .left, isStrict: false))
    }

    func testDisplayAboveDoesNotTakeAnEdge() {
        let above = ScreenLayout(
            frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 875)
        )
        XCTAssertEqual(CallEdge.choose(for: main, others: [above]).side, .right)
    }

    func testDockOnTheRightTakesThatEdge() {
        let docked = ScreenLayout(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1370, height: 875)
        )
        XCTAssertEqual(CallEdge.choose(for: docked, others: []), CallEdge(side: .left, isStrict: false))
    }

    func testBothEdgesTakenFallsBackToStrictRight() {
        let left = ScreenLayout(
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        )
        let right = ScreenLayout(
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        )
        XCTAssertEqual(CallEdge.choose(for: main, others: [left, right]), CallEdge(side: .right, isStrict: true))
    }

    func testManualChoiceIsKeptAndMarkedStrictWhenTaken() {
        let right = ScreenLayout(
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        )
        XCTAssertEqual(
            CallEdge.choose(for: main, others: [right], preference: .right),
            CallEdge(side: .right, isStrict: true)
        )
        XCTAssertEqual(
            CallEdge.choose(for: main, others: [right], preference: .left),
            CallEdge(side: .left, isStrict: false)
        )
    }

    func testZoneSitsAtTheEdgeInTheMiddleThird() {
        let edge = CallEdge(side: .right, isStrict: false)
        let zone = edge.zone(on: main, depth: 4, verticalRange: 0.35...0.65)
        XCTAssertEqual(zone.maxX, 1440)
        XCTAssertEqual(zone.width, 4)
        // The visible frame is 805 pt tall and ends at y = 875.
        XCTAssertEqual(zone.maxY, 875 - 805 * 0.35, accuracy: 0.001)
        XCTAssertEqual(zone.minY, 875 - 805 * 0.65, accuracy: 0.001)

        let leftZone = CallEdge(side: .left, isStrict: true).zone(on: main, depth: 10, verticalRange: 0.35...0.65)
        XCTAssertEqual(leftZone.minX, 0)
        XCTAssertEqual(leftZone.width, 10)
    }

    func testDistanceToTheEdge() {
        XCTAssertEqual(CallEdge(side: .right, isStrict: false).distance(of: CGPoint(x: 1430, y: 400), on: main), 10)
        XCTAssertEqual(CallEdge(side: .left, isStrict: false).distance(of: CGPoint(x: 3, y: 400), on: main), 3)
    }
}

final class EdgeIntentDetectorTests: XCTestCase {
    private typealias Input = EdgeIntentDetector.Input

    private let zone = CGRect(x: 1436, y: 300, width: 4, height: 300)
    private let pad = CGRect(x: 1340, y: 380, width: 100, height: 140)
    private let free = EdgeIntentDetector.Rules.free

    private func scene(at x: CGFloat, pad: CGRect? = nil, holds: Bool = false) -> EdgeIntentDetector.Scene {
        EdgeIntentDetector.Scene(zone: zone, padFrame: pad, distanceToEdge: 1440 - x, holdsOpen: holds)
    }

    /// Feeds a cursor that stands still at `x` from `start` to `end`, 60 times a second.
    private func rest(_ detector: inout EdgeIntentDetector, x: CGFloat, from start: Double, to end: Double, pad: CGRect? = nil) {
        var time = start
        while time <= end + 0.0001 {
            detector.update(Input(location: CGPoint(x: x, y: 450), time: time), scene: scene(at: x, pad: pad), rules: free)
            time += 1.0 / 60
        }
    }

    func testRestingInTheZonePeeksThenOpens() {
        var detector = EdgeIntentDetector()
        rest(&detector, x: 1438, from: 0, to: 0.2)
        XCTAssertEqual(detector.phase, .idle, "250 ms have not passed")
        XCTAssertTrue(detector.needsContinuousInput)

        rest(&detector, x: 1438, from: 0.2, to: 0.3)
        XCTAssertEqual(detector.phase, .peek)

        rest(&detector, x: 1438, from: 0.3, to: 0.5, pad: pad)
        XCTAssertEqual(detector.phase, .open)
    }

    func testPushingOnTowardsTheEdgeOpensAtOnce() {
        var detector = EdgeIntentDetector()
        rest(&detector, x: 1437, from: 0, to: 0.27)
        XCTAssertEqual(detector.phase, .peek)
        detector.update(Input(location: CGPoint(x: 1439.5, y: 450), time: 0.29), scene: scene(at: 1439.5, pad: pad), rules: free)
        XCTAssertEqual(detector.phase, .open)
    }

    func testFastPassDoesNothing() {
        // 1500 pt/s straight through the zone, as on the way to the next display.
        var detector = EdgeIntentDetector()
        var time = 0.0
        var x: CGFloat = 1313 // lands on 1438, inside the zone
        while x < 1440 {
            detector.update(Input(location: CGPoint(x: x, y: 450), time: time), scene: scene(at: x), rules: free)
            x += 25
            time += 1.0 / 60
        }
        XCTAssertEqual(detector.phase, .idle)
        XCTAssertGreaterThan(detector.speed, 600)
    }

    func testFastArrivalThenRestStillCallsThePadByDefault() {
        // A flick to a free edge: the cursor hits the edge and stops there.
        var detector = EdgeIntentDetector()
        var time = 0.0
        for x in stride(from: CGFloat(1200), through: 1438, by: 34) {
            detector.update(Input(location: CGPoint(x: x, y: 450), time: time), scene: scene(at: x), rules: free)
            time += 1.0 / 60
        }
        rest(&detector, x: 1438, from: time, to: time + 0.5)
        XCTAssertNotEqual(detector.phase, .idle)
    }

    func testFastArrivalCanBeRejectedUntilTheCursorLeaves() {
        var rules = free
        rules.fastEntryRejects = true
        var detector = EdgeIntentDetector()
        var time = 0.0
        for x in stride(from: CGFloat(1200), through: 1438, by: 34) {
            detector.update(Input(location: CGPoint(x: x, y: 450), time: time), scene: scene(at: x), rules: rules)
            time += 1.0 / 60
        }
        for _ in 0..<60 {
            detector.update(Input(location: CGPoint(x: 1438, y: 450), time: time), scene: scene(at: 1438), rules: rules)
            time += 1.0 / 60
        }
        XCTAssertEqual(detector.phase, .idle, "it came in too fast")

        // Out and back in, slowly this time.
        for x in [CGFloat(1400), 1410, 1420, 1430, 1437] {
            time += 0.1
            detector.update(Input(location: CGPoint(x: x, y: 450), time: time), scene: scene(at: x), rules: rules)
        }
        for _ in 0..<60 {
            time += 1.0 / 60
            detector.update(Input(location: CGPoint(x: 1437, y: 450), time: time), scene: scene(at: 1437), rules: rules)
        }
        XCTAssertNotEqual(detector.phase, .idle)
    }

    func testPressedButtonKeepsThePadAway() {
        var detector = EdgeIntentDetector()
        var time = 0.0
        while time < 1 {
            detector.update(
                Input(location: CGPoint(x: 1438, y: 450), isMouseDown: true, time: time),
                scene: scene(at: 1438),
                rules: free
            )
            time += 1.0 / 60
        }
        XCTAssertEqual(detector.phase, .idle)
        XCTAssertFalse(detector.needsContinuousInput)
    }

    func testStrictEdgeNeedsASlowerAndLongerStop() {
        let strict = EdgeIntentDetector.Rules.strict
        var detector = EdgeIntentDetector()
        var time = 0.0
        while time <= 0.4 {
            detector.update(Input(location: CGPoint(x: 1438, y: 450), time: time), scene: scene(at: 1438), rules: strict)
            time += 1.0 / 60
        }
        XCTAssertEqual(detector.phase, .idle, "450 ms have not passed")
        while time <= 0.5 {
            detector.update(Input(location: CGPoint(x: 1438, y: 450), time: time), scene: scene(at: 1438), rules: strict)
            time += 1.0 / 60
        }
        XCTAssertEqual(detector.phase, .peek)
    }

    func testLeavingHidesThePadAfterAPause() {
        var detector = EdgeIntentDetector()
        rest(&detector, x: 1438, from: 0, to: 0.6, pad: pad)
        XCTAssertEqual(detector.phase, .open)

        // On the pad itself: stays.
        detector.update(Input(location: CGPoint(x: 1380, y: 450), time: 0.7), scene: scene(at: 1380, pad: pad), rules: free)
        detector.update(Input(location: CGPoint(x: 1380, y: 450), time: 2), scene: scene(at: 1380, pad: pad), rules: free)
        XCTAssertEqual(detector.phase, .open)

        // Away for 200 ms, back, away again: the pause starts over.
        detector.update(Input(location: CGPoint(x: 900, y: 450), time: 2.1), scene: scene(at: 900, pad: pad), rules: free)
        detector.update(Input(location: CGPoint(x: 900, y: 450), time: 2.3), scene: scene(at: 900, pad: pad), rules: free)
        XCTAssertEqual(detector.phase, .open)
        detector.update(Input(location: CGPoint(x: 1380, y: 450), time: 2.35), scene: scene(at: 1380, pad: pad), rules: free)
        detector.update(Input(location: CGPoint(x: 900, y: 450), time: 2.4), scene: scene(at: 900, pad: pad), rules: free)
        detector.update(Input(location: CGPoint(x: 900, y: 450), time: 2.6), scene: scene(at: 900, pad: pad), rules: free)
        XCTAssertEqual(detector.phase, .open)
        detector.update(Input(location: CGPoint(x: 900, y: 450), time: 2.75), scene: scene(at: 900, pad: pad), rules: free)
        XCTAssertEqual(detector.phase, .idle)
        XCTAssertFalse(detector.needsContinuousInput)
    }

    func testAnOpenDraftHoldsThePad() {
        var detector = EdgeIntentDetector()
        detector.forceOpen()
        XCTAssertEqual(detector.phase, .open)
        detector.update(Input(location: CGPoint(x: 200, y: 200), time: 0), scene: scene(at: 200, pad: pad, holds: true), rules: free)
        detector.update(Input(location: CGPoint(x: 200, y: 200), time: 10), scene: scene(at: 200, pad: pad, holds: true), rules: free)
        XCTAssertEqual(detector.phase, .open)

        detector.update(Input(location: CGPoint(x: 200, y: 200), time: 10.1), scene: scene(at: 200, pad: pad), rules: free)
        detector.update(Input(location: CGPoint(x: 200, y: 200), time: 10.5), scene: scene(at: 200, pad: pad), rules: free)
        XCTAssertEqual(detector.phase, .idle)
    }

    func testResetHidesAtOnce() {
        var detector = EdgeIntentDetector()
        detector.forceOpen()
        detector.reset()
        XCTAssertEqual(detector.phase, .idle)
        XCTAssertFalse(detector.needsContinuousInput)
    }

    func testPeekWithoutFollowUpHides() {
        var detector = EdgeIntentDetector()
        rest(&detector, x: 1438, from: 0, to: 0.27)
        XCTAssertEqual(detector.phase, .peek)
        detector.update(Input(location: CGPoint(x: 1000, y: 450), time: 0.3), scene: scene(at: 1000, pad: pad), rules: free)
        detector.update(Input(location: CGPoint(x: 1000, y: 450), time: 0.65), scene: scene(at: 1000, pad: pad), rules: free)
        XCTAssertEqual(detector.phase, .idle)
    }
}

final class PlainTextPlanTests: XCTestCase {
    func testFirstLineIsTheTitleTheRestAreTasks() {
        let plan = PlainTextPlan.make(from: "План на день\nДоделать экран\n\n  Написать пост  \n")
        XCTAssertEqual(plan.title, "План на день")
        XCTAssertEqual(plan.blocks.map(\.kind), [.todo, .todo])
        XCTAssertEqual(plan.blocks.map(\.text), ["Доделать экран", "Написать пост"])
        XCTAssertFalse(plan.isEmpty)
    }

    func testMarkersAreUnderstood() {
        let text = "Кошелёк\n## Экран\n[] пустые состояния\n[x] ошибки\n- заметка\n\tвложенный пункт\nпросто строка"
        let plan = PlainTextPlan.make(from: text)
        XCTAssertEqual(plan.title, "Кошелёк")
        XCTAssertEqual(plan.blocks.map(\.kind), [.heading2, .todo, .todo, .bullet, .todo, .todo])
        XCTAssertEqual(plan.blocks.map(\.done), [false, false, true, false, false, false])
        XCTAssertEqual(plan.blocks.map(\.indent), [0, 0, 0, 0, 1, 0])
        XCTAssertEqual(plan.blocks[1].text, "пустые состояния")
    }

    func testMarkerOnTheFirstLineMeansNoTitle() {
        let plan = PlainTextPlan.make(from: "- молоко\n- хлеб")
        XCTAssertEqual(plan.title, "")
        XCTAssertEqual(plan.blocks.map(\.text), ["молоко", "хлеб"])
        XCTAssertEqual(plan.blocks.map(\.kind), [.bullet, .bullet])
    }

    func testPlainLinesCanStayText() {
        let plan = PlainTextPlan.make(from: "Заметка\nпервая\r\nвторая", plainLineKind: .text)
        XCTAssertEqual(plan.blocks.map(\.kind), [.text, .text])
        XCTAssertEqual(plan.blocks.map(\.text), ["первая", "вторая"])
    }

    func testLabelShrinksUntilItsLongestWordFits() {
        XCTAssertEqual(LabelFit.words(of: "Записать задачи"), ["Записать", "задачи"])
        XCTAssertEqual(LabelFit.words(of: "Jot  down\ntasks"), ["Jot", "down", "tasks"])
        // It fits: the size stays.
        XCTAssertEqual(LabelFit.fontSize(base: 20, minimum: 13, widestWord: 60, available: 64), 20)
        // «Записать» is 69 pt wide at 20 pt and the sheet shows 64 pt.
        let fitted = LabelFit.fontSize(base: 20, minimum: 13, widestWord: 69, available: 64)
        XCTAssertEqual(fitted, 18.5)
        XCTAssertLessThanOrEqual(69 * fitted / 20, 64)
        // Never below the minimum, never a division by zero.
        XCTAssertEqual(LabelFit.fontSize(base: 20, minimum: 13, widestWord: 400, available: 64), 13)
        XCTAssertEqual(LabelFit.fontSize(base: 20, minimum: 13, widestWord: 0, available: 64), 20)
        XCTAssertEqual(LabelFit.fontSize(base: 20, minimum: 13, widestWord: 69, available: 0), 20)
    }

    func testEmptyInputGivesNothing() {
        XCTAssertTrue(PlainTextPlan.make(from: "  \n\n\t").isEmpty)
        XCTAssertTrue(PlainTextPlan.make(from: "").isEmpty)
        // A marker with nothing after it is not a block.
        XCTAssertEqual(PlainTextPlan.make(from: "Список\n-  \n[] ").blocks, [])
    }

    func testIndentIsCappedAtTwoLevels() {
        let plan = PlainTextPlan.make(from: "Т\n\t\t\t\tглубоко\n      шесть пробелов")
        XCTAssertEqual(plan.blocks.map(\.indent), [2, 2])
    }
}
