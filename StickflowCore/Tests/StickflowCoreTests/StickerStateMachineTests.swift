// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

@testable import StickflowCore
import XCTest

final class StickerStateMachineTests: XCTestCase {
    private typealias Input = StickerStateMachine.Input
    private typealias Outcome = StickerStateMachine.Outcome

    private let rules = StickerStateMachine.Rules()

    private func over(key: Bool = false, mouse: Bool = false, at time: TimeInterval) -> Input {
        Input(isOver: true, isNear: true, isEditKeyDown: key, isMouseDown: mouse, time: time)
    }

    private func away(key: Bool = false, at time: TimeInterval) -> Input {
        Input(isOver: false, isNear: false, isEditKeyDown: key, time: time)
    }

    func testStartsAtRestAndNeedsNothing() {
        let machine = StickerStateMachine()
        XCTAssertEqual(machine.mode, .rest)
        XCTAssertFalse(machine.needsContinuousInput)
    }

    func testFadesAfterTheDelayAndComesBack() {
        var machine = StickerStateMachine()
        XCTAssertEqual(machine.pointerMoved(over(at: 0), rules: rules), Outcome())
        XCTAssertEqual(machine.mode, .rest, "no fade before the delay")
        XCTAssertTrue(machine.needsContinuousInput, "the fade timer runs even if the mouse is still")

        _ = machine.pointerMoved(over(at: 0.11), rules: rules)
        XCTAssertEqual(machine.mode, .rest)
        _ = machine.pointerMoved(over(at: 0.12), rules: rules)
        XCTAssertEqual(machine.mode, .faded)

        _ = machine.pointerMoved(away(at: 0.5), rules: rules)
        XCTAssertEqual(machine.mode, .rest)
        XCTAssertFalse(machine.needsContinuousInput)
    }

    func testFadeCanBeSwitchedOff() {
        var machine = StickerStateMachine()
        let noFade = StickerStateMachine.Rules(fadeEnabled: false)
        _ = machine.pointerMoved(over(at: 0), rules: noFade)
        _ = machine.pointerMoved(over(at: 5), rules: noFade)
        XCTAssertEqual(machine.mode, .rest)

        // Switched off while the sticker is faded: it comes back at once.
        _ = machine.pointerMoved(over(at: 6), rules: rules)
        XCTAssertEqual(machine.mode, .faded)
        _ = machine.pointerMoved(over(at: 6.1), rules: noFade)
        XCTAssertEqual(machine.mode, .rest)
    }

    func testEditKeyOverTheStickerEntersEditMode() {
        var machine = StickerStateMachine()
        let outcome = machine.pointerMoved(over(key: true, at: 0), rules: rules)
        XCTAssertEqual(machine.mode, .editMode)
        XCTAssertEqual(outcome, Outcome(hidesHint: true))
        XCTAssertTrue(machine.needsContinuousInput)
    }

    func testEditKeyAwayFromTheStickerDoesNothing() {
        var machine = StickerStateMachine()
        _ = machine.pointerMoved(away(key: true, at: 0), rules: rules)
        XCTAssertEqual(machine.mode, .rest)
    }

    func testEditKeyWinsOverFade() {
        var machine = StickerStateMachine()
        _ = machine.pointerMoved(over(at: 0), rules: rules)
        _ = machine.pointerMoved(over(at: 1), rules: rules)
        XCTAssertEqual(machine.mode, .faded)
        _ = machine.pointerMoved(over(key: true, at: 1.1), rules: rules)
        XCTAssertEqual(machine.mode, .editMode)
    }

    func testEditKeyIsIgnoredWhileAMouseButtonIsDown() {
        // ⌥-drag in Figma copies a layer; the sticker in its way must stay out of it.
        var machine = StickerStateMachine()
        _ = machine.pointerMoved(over(key: true, mouse: true, at: 0), rules: rules)
        XCTAssertEqual(machine.mode, .rest)

        let lenient = StickerStateMachine.Rules(suppressEditWhileMouseDown: false)
        _ = machine.pointerMoved(over(key: true, mouse: true, at: 0.01), rules: lenient)
        XCTAssertEqual(machine.mode, .editMode)
    }

    func testEditModeSurvivesTheGracePeriodThenEnds() {
        var machine = StickerStateMachine()
        _ = machine.pointerMoved(over(key: true, at: 0), rules: rules)

        _ = machine.pointerMoved(over(at: 1), rules: rules) // key released
        XCTAssertEqual(machine.mode, .editMode)
        _ = machine.pointerMoved(over(at: 1.1), rules: rules)
        XCTAssertEqual(machine.mode, .editMode, "still inside the grace period")
        _ = machine.pointerMoved(over(at: 1.2), rules: rules)
        XCTAssertEqual(machine.mode, .rest)
    }

    func testPressingTheKeyAgainInsideTheGracePeriodKeepsEditMode() {
        var machine = StickerStateMachine()
        _ = machine.pointerMoved(over(key: true, at: 0), rules: rules)
        _ = machine.pointerMoved(over(at: 1), rules: rules)
        _ = machine.pointerMoved(over(key: true, at: 1.05), rules: rules)
        _ = machine.pointerMoved(over(key: true, at: 5), rules: rules)
        XCTAssertEqual(machine.mode, .editMode)
    }

    func testLeavingTheStickerEndsEditModeAfterTheGracePeriod() {
        var machine = StickerStateMachine()
        _ = machine.pointerMoved(over(key: true, at: 0), rules: rules)
        _ = machine.pointerMoved(away(key: true, at: 1), rules: rules)
        XCTAssertEqual(machine.mode, .editMode)
        _ = machine.pointerMoved(away(key: true, at: 1.2), rules: rules)
        XCTAssertEqual(machine.mode, .rest)
        XCTAssertFalse(machine.needsContinuousInput)
    }

    func testAfterEditModeTheFadeDelayStartsAgain() {
        var machine = StickerStateMachine()
        _ = machine.pointerMoved(over(key: true, at: 0), rules: rules)
        _ = machine.pointerMoved(over(at: 1), rules: rules)
        _ = machine.pointerMoved(over(at: 1.2), rules: rules)
        XCTAssertEqual(machine.mode, .rest)
        _ = machine.pointerMoved(over(at: 1.25), rules: rules)
        XCTAssertEqual(machine.mode, .rest, "the cursor has rested here for 50 ms only")
        _ = machine.pointerMoved(over(at: 1.4), rules: rules)
        XCTAssertEqual(machine.mode, .faded)
    }

    func testKeyHeldOnArrivalCanBeRequiredToBePressedAgain() {
        let strict = StickerStateMachine.Rules(keyMustBePressedAtSticker: true)
        var machine = StickerStateMachine()
        _ = machine.pointerMoved(away(key: true, at: 0), rules: strict)
        _ = machine.pointerMoved(over(key: true, at: 0.1), rules: strict)
        XCTAssertNotEqual(machine.mode, .editMode, "the key was already down when the cursor arrived")

        _ = machine.pointerMoved(over(at: 0.2), rules: strict) // released
        _ = machine.pointerMoved(over(key: true, at: 0.3), rules: strict) // pressed here
        XCTAssertEqual(machine.mode, .editMode)

        // Without the rule the key counts wherever it was pressed.
        var relaxed = StickerStateMachine()
        _ = relaxed.pointerMoved(away(key: true, at: 0), rules: rules)
        _ = relaxed.pointerMoved(over(key: true, at: 0.1), rules: rules)
        XCTAssertEqual(relaxed.mode, .editMode)
    }

    func testHintAppearsOncePerHover() {
        var machine = StickerStateMachine()
        XCTAssertFalse(machine.pointerMoved(over(at: 0), rules: rules).showsHint)
        XCTAssertFalse(machine.pointerMoved(over(at: 0.9), rules: rules).showsHint)
        XCTAssertTrue(machine.pointerMoved(over(at: 1), rules: rules).showsHint)
        XCTAssertFalse(machine.pointerMoved(over(at: 2), rules: rules).showsHint)

        _ = machine.pointerMoved(away(at: 3), rules: rules)
        _ = machine.pointerMoved(over(at: 4), rules: rules)
        XCTAssertTrue(machine.pointerMoved(over(at: 5), rules: rules).showsHint, "a new hover may show it again")
    }

    func testNoHintRightAfterUsingTheKey() {
        var machine = StickerStateMachine()
        _ = machine.pointerMoved(over(key: true, at: 0), rules: rules)
        _ = machine.pointerMoved(over(at: 1), rules: rules)
        _ = machine.pointerMoved(over(at: 1.2), rules: rules)
        XCTAssertEqual(machine.mode, .rest)
        XCTAssertFalse(machine.pointerMoved(over(at: 5), rules: rules).showsHint)
    }

    func testEditingIgnoresThePointerUntilItEnds() {
        var machine = StickerStateMachine()
        _ = machine.pointerMoved(over(key: true, at: 0), rules: rules)
        machine.beginEditing()
        XCTAssertEqual(machine.mode, .editing)
        XCTAssertFalse(machine.needsContinuousInput)

        XCTAssertEqual(machine.pointerMoved(away(at: 10), rules: rules), Outcome())
        XCTAssertEqual(machine.mode, .editing, "no key and no cursor needed while typing")

        machine.endEditing()
        XCTAssertEqual(machine.mode, .rest)
        XCTAssertFalse(machine.needsContinuousInput)
    }

    func testPendingReleaseCanBeCancelled() {
        var machine = StickerStateMachine()
        _ = machine.pointerMoved(over(key: true, at: 0), rules: rules)
        _ = machine.pointerMoved(over(at: 1), rules: rules) // grace period starts
        machine.cancelPendingRelease() // e.g. a menu was open for a while
        _ = machine.pointerMoved(over(at: 9), rules: rules)
        XCTAssertEqual(machine.mode, .editMode, "the grace period starts over")
        _ = machine.pointerMoved(over(at: 9.1), rules: rules)
        XCTAssertEqual(machine.mode, .editMode)
        _ = machine.pointerMoved(over(at: 9.2), rules: rules)
        XCTAssertEqual(machine.mode, .rest)
    }
}
