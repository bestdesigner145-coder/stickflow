// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import StickflowCore
import XCTest

final class MotionMathTests: XCTestCase {
    func testBezierEndsAndShape() {
        let easeOut = CubicBezier(0.23, 1, 0.32, 1)
        XCTAssertEqual(easeOut.value(at: 0), 0)
        XCTAssertEqual(easeOut.value(at: 1), 1)
        XCTAssertEqual(easeOut.value(at: -1), 0)
        XCTAssertEqual(easeOut.value(at: 2), 1)
        // Ease-out is ahead of time early on; it never goes backwards.
        XCTAssertGreaterThan(easeOut.value(at: 0.2), 0.5)
        var previous = 0.0
        for step in 1...20 {
            let value = easeOut.value(at: Double(step) / 20)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
        // A straight line stays a straight line.
        let linear = CubicBezier(0.25, 0.25, 0.75, 0.75)
        XCTAssertEqual(linear.value(at: 0.37), 0.37, accuracy: 0.001)
        // Ease-in-out is symmetric.
        let easeInOut = CubicBezier(0.77, 0, 0.175, 1)
        XCTAssertLessThan(easeInOut.value(at: 0.2), 0.1)
        XCTAssertGreaterThan(easeInOut.value(at: 0.8), 0.9)
    }

    func testSpringSettlesAndBounces() {
        let paper = Spring(duration: 0.4, bounce: 0.2)
        XCTAssertEqual(paper.value(at: 0), 0)
        XCTAssertEqual(paper.value(at: 5), 1, accuracy: 0.0001)
        let peak = stride(from: 0.0, through: 1, by: 0.005).map(paper.value(at:)).max() ?? 0
        XCTAssertGreaterThan(peak, 1.0, "a bouncy spring overshoots")
        XCTAssertLessThan(peak, 1.2)
        XCTAssertEqual(paper.value(at: paper.settlingTime), 1, accuracy: 0.002)

        let soft = Spring(duration: 0.35, bounce: 0)
        let softPeak = stride(from: 0.0, through: 2, by: 0.005).map(soft.value(at:)).max() ?? 0
        XCTAssertLessThanOrEqual(softPeak, 1.0001, "no bounce, no overshoot")
        XCTAssertEqual(soft.value(at: 2), 1, accuracy: 0.0001)

        XCTAssertEqual(Spring(duration: 0, bounce: 0).value(at: 0.1), 1)
        XCTAssertEqual(Spring(duration: 0, bounce: 0).settlingTime, 0)
    }

    func testFlightPathStartsEndsAndRises() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 200, y: 100)
        XCTAssertEqual(FlightPath.point(from: start, to: end, progress: 0, lift: 40), start)
        XCTAssertEqual(FlightPath.point(from: start, to: end, progress: 1, lift: 40), end)
        XCTAssertEqual(FlightPath.point(from: start, to: end, progress: 3, lift: 40), end)
        let middle = FlightPath.point(from: start, to: end, progress: 0.5, lift: 40)
        XCTAssertEqual(middle.x, 100, accuracy: 0.001)
        XCTAssertEqual(middle.y, 70, accuracy: 0.001, "half of the lift above the straight line")
    }

    func testFoldingACorner() throws {
        let paper = CGRect(x: 0, y: 0, width: 100, height: 100)
        let fold = try XCTUnwrap(PaperFold.make(paper: paper, corner: CGPoint(x: 100, y: 0), pulledTo: CGPoint(x: 80, y: 20)))
        // The corner triangle (100,0) (80,0) (100,20) turns over and lands on (80,20) (80,0) (100,20).
        XCTAssertEqual(fold.flap.count, 3)
        for expected in [CGPoint(x: 80, y: 20), CGPoint(x: 80, y: 0), CGPoint(x: 100, y: 20)] {
            XCTAssertTrue(
                fold.flap.contains { abs($0.x - expected.x) < 0.001 && abs($0.y - expected.y) < 0.001 },
                "\(expected) is a corner of the flap: \(fold.flap)"
            )
        }
        XCTAssertEqual(fold.kept.count, 5, "the sheet without its corner has five corners")
        XCTAssertFalse(fold.kept.contains { abs($0.x - 100) < 0.001 && abs($0.y) < 0.001 }, "the pulled corner is gone")
        XCTAssertEqual(area(fold.kept) + area(fold.flap), 100 * 100, accuracy: 0.01, "no paper is lost")
    }

    func testFoldNeedsMovement() {
        let paper = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(PaperFold.make(paper: paper, corner: CGPoint(x: 100, y: 0), pulledTo: CGPoint(x: 100.2, y: 0)))
        // Pulling the corner away from the sheet folds nothing.
        XCTAssertNil(PaperFold.make(paper: paper, corner: CGPoint(x: 100, y: 0), pulledTo: CGPoint(x: 400, y: -300)))
    }

    func testDeepFoldKeepsLessPaper() throws {
        let paper = CGRect(x: 0, y: 0, width: 200, height: 100)
        let corner = CGPoint(x: 200, y: 0)
        let small = try XCTUnwrap(PaperFold.make(paper: paper, corner: corner, pulledTo: CGPoint(x: 190, y: 10)))
        let deep = try XCTUnwrap(PaperFold.make(paper: paper, corner: corner, pulledTo: CGPoint(x: 100, y: 80)))
        XCTAssertGreaterThan(area(small.kept), area(deep.kept))
        XCTAssertGreaterThan(area(deep.flap), area(small.flap))
    }

    func testPeelThresholds() {
        let gesture = PeelGesture()
        XCTAssertFalse(gesture.comesOff(distance: 40, speed: 100))
        XCTAssertTrue(gesture.comesOff(distance: 71, speed: 0), "pulled far enough")
        XCTAssertTrue(gesture.comesOff(distance: 20, speed: 900), "a quick jerk is enough")
        XCTAssertFalse(gesture.comesOff(distance: 70, speed: 800), "the thresholds themselves do not count")
    }

    func testReleaseSpeedLooksAtTheLastMoments() {
        let slowThenFast: [(point: CGPoint, time: TimeInterval)] = [
            (CGPoint(x: 0, y: 0), 0), (CGPoint(x: 5, y: 0), 0.5),
            (CGPoint(x: 10, y: 0), 0.95), (CGPoint(x: 60, y: 0), 1.0),
        ]
        XCTAssertEqual(PeelGesture.releaseSpeed(trail: slowThenFast), 1000, accuracy: 1)
        XCTAssertEqual(PeelGesture.releaseSpeed(trail: []), 0)
        XCTAssertEqual(PeelGesture.releaseSpeed(trail: [(CGPoint(x: 1, y: 1), 3)]), 0)
    }

    /// Area of a polygon by the shoelace formula.
    private func area(_ polygon: [CGPoint]) -> Double {
        var sum = 0.0
        for index in polygon.indices {
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            sum += Double(current.x * next.y - next.x * current.y)
        }
        return abs(sum) / 2
    }
}
