// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import StickflowCore
import XCTest

final class StickerStateMachineTests: XCTestCase {
    private typealias Input = StickerStateMachine.Input
    private typealias Outcome = StickerStateMachine.Outcome

    /// Most tests use a fade delay, to show that the timer works when one is set.
    private let rules = StickerStateMachine.Rules(fadeDelay: 0.12)

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

    func testFadesAtOnceByDefault() {
        // Spec 4.7: no pause before the fade starts.
        var machine = StickerStateMachine()
        _ = machine.pointerMoved(over(at: 0), rules: StickerStateMachine.Rules())
        XCTAssertEqual(machine.mode, .faded)
        _ = machine.pointerMoved(away(at: 0.01), rules: StickerStateMachine.Rules())
        XCTAssertEqual(machine.mode, .rest)
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
        let noFade = StickerStateMachine.Rules(fadeEnabled: false, fadeDelay: 0.12)
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

        let lenient = StickerStateMachine.Rules(fadeDelay: 0.12, suppressEditWhileMouseDown: false)
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
        let strict = StickerStateMachine.Rules(fadeDelay: 0.12, keyMustBePressedAtSticker: true)
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

    func testHaloFadesAStickerTheCursorIsOnlyNear() {
        var machine = StickerStateMachine()
        let noDelay = StickerStateMachine.Rules()
        let nearby = Input(isOver: false, isNear: false, isEditKeyDown: false, isInHalo: true, time: 0)
        XCTAssertFalse(machine.pointerMoved(nearby, rules: noDelay).showsHint)
        XCTAssertEqual(machine.mode, .faded, "the halo reaches it, so it fades")
        XCTAssertTrue(machine.needsContinuousInput)

        // The hint is for the sticker under the cursor only.
        let later = Input(isOver: false, isNear: false, isEditKeyDown: false, isInHalo: true, time: 5)
        XCTAssertFalse(machine.pointerMoved(later, rules: noDelay).showsHint)

        _ = machine.pointerMoved(away(at: 6), rules: noDelay)
        XCTAssertEqual(machine.mode, .rest)
        XCTAssertFalse(machine.needsContinuousInput)
    }

    func testHintCountsTimeOverThePaperNotInTheHalo() {
        var machine = StickerStateMachine()
        let noDelay = StickerStateMachine.Rules()
        _ = machine.pointerMoved(Input(isOver: false, isNear: false, isEditKeyDown: false, isInHalo: true, time: 0), rules: noDelay)
        _ = machine.pointerMoved(Input(isOver: false, isNear: false, isEditKeyDown: false, isInHalo: true, time: 3), rules: noDelay)
        // Only now the cursor comes onto the paper.
        XCTAssertFalse(machine.pointerMoved(over(at: 3.1), rules: noDelay).showsHint)
        XCTAssertFalse(machine.pointerMoved(over(at: 4.0), rules: noDelay).showsHint)
        XCTAssertTrue(machine.pointerMoved(over(at: 4.2), rules: noDelay).showsHint)
    }

    func testHaloOpacityByDistance() {
        let halo = HaloFade()
        XCTAssertEqual(halo.opacity(distance: 0), 0.2)
        XCTAssertEqual(halo.opacity(distance: 40), 0.2)
        XCTAssertEqual(halo.opacity(distance: 140), 1)
        XCTAssertEqual(halo.opacity(distance: 500), 1)
        XCTAssertEqual(halo.opacity(distance: 90), 0.6, accuracy: 0.0001, "half way is half faded")
        var previous = 0.0
        for distance in stride(from: 0.0, through: 150, by: 5) {
            let value = halo.opacity(distance: distance)
            XCTAssertGreaterThanOrEqual(value, previous, "farther is never more faded")
            previous = value
        }
        XCTAssertTrue(halo.reaches(distance: 139))
        XCTAssertFalse(halo.reaches(distance: 140))
        // A halo no wider than its core switches off cleanly.
        XCTAssertEqual(HaloFade(radius: 40, fullFadeWithin: 40).opacity(distance: 41), 1)
    }

    func testDistanceToASticker() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(HaloFade.distance(from: CGPoint(x: 150, y: 150), to: rect), 0)
        XCTAssertEqual(HaloFade.distance(from: CGPoint(x: 60, y: 150), to: rect), 40)
        XCTAssertEqual(HaloFade.distance(from: CGPoint(x: 150, y: 230), to: rect), 30)
        XCTAssertEqual(HaloFade.distance(from: CGPoint(x: 330, y: 240), to: rect), 50, accuracy: 0.0001)
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
