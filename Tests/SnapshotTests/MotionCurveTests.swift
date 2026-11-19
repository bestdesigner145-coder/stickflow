// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

@testable import Stickflow
import XCTest

/// Fix K1: the pad goes back on the `drawer` curve played backwards.
@MainActor
final class MotionCurveTests: XCTestCase {
    func testTheReversedCurveIsTheSameMoveBackwards() {
        let drawer = MotionCurve.drawer
        let back = drawer.reversed
        for step in 0...10 {
            let progress = Double(step) / 10
            XCTAssertEqual(back.value(at: progress), 1 - drawer.value(at: 1 - progress), accuracy: 0.01, "at \(progress)")
        }
    }

    func testGoingBackStartsSlowly() {
        // Played forwards, most of the way is covered in the first third: the pad seems to vanish.
        XCTAssertGreaterThan(MotionCurve.drawer.value(at: 1.0 / 3), 0.6)
        XCTAssertLessThan(MotionCurve.drawer.reversed.value(at: 1.0 / 3), 0.4)
    }
}
