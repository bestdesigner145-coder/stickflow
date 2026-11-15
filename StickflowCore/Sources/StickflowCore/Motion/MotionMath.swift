// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// A CSS-style easing curve, `cubic-bezier(x1, y1, x2, y2)` (spec 6.7).
public struct CubicBezier: Equatable, Sendable {
    public let c1x: Double
    public let c1y: Double
    public let c2x: Double
    public let c2y: Double

    public init(_ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double) {
        self.c1x = c1x
        self.c1y = c1y
        self.c2x = c2x
        self.c2y = c2y
    }

    /// How far along the animation is when `progress` of its time has passed.
    public func value(at progress: Double) -> Double {
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        // The curve is given as (x(t), y(t)); find t for this x by bisection.
        var low = 0.0
        var high = 1.0
        var parameter = progress
        for _ in 0..<40 {
            let x = Self.component(parameter, c1x, c2x)
            if abs(x - progress) < 1e-6 { break }
            if x < progress { low = parameter } else { high = parameter }
            parameter = (low + high) / 2
        }
        return Self.component(parameter, c1y, c2y)
    }

    private static func component(_ parameter: Double, _ first: Double, _ second: Double) -> Double {
        let inverse = 1 - parameter
        return 3 * inverse * inverse * parameter * first + 3 * inverse * parameter * parameter * second
            + parameter * parameter * parameter
    }
}

/// A spring given the way designers think of it: how long it takes and how
/// bouncy it is (spec 6.7: `springPaper` is 0.4 s with a bounce of 0.2).
public struct Spring: Equatable, Sendable {
    public let duration: Double
    public let bounce: Double

    public init(duration: Double, bounce: Double) {
        self.duration = duration
        self.bounce = bounce
    }

    /// Position at `time` seconds, moving from 0 to 1. With a bounce it passes 1 and comes back.
    public func value(at time: Double) -> Double {
        guard duration > 0, time > 0 else { return time > 0 ? 1 : 0 }
        let frequency = 2 * Double.pi / duration
        let damping = min(max(1 - bounce, 0.05), 1)
        if damping >= 1 {
            // Critically damped: no overshoot.
            return 1 - exp(-frequency * time) * (1 + frequency * time)
        }
        let damped = frequency * (1 - damping * damping).squareRoot()
        let envelope = exp(-damping * frequency * time)
        return 1 - envelope * (cos(damped * time) + damping * frequency / damped * sin(damped * time))
    }

    /// Seconds after which the spring is within a thousandth of its target.
    public var settlingTime: Double {
        guard duration > 0 else { return 0 }
        let damping = min(max(1 - bounce, 0.05), 1)
        let frequency = 2 * Double.pi / duration
        return log(1000) / (damping * frequency)
    }
}

/// The arc a sticker flies along from the draft to its place (spec 4.4).
public enum FlightPath {
    /// The control point of the arc, a quadratic Bézier curve; with it the same
    /// path can be handed to Core Animation.
    public static func control(from start: CGPoint, to end: CGPoint, lift: CGFloat) -> CGPoint {
        CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + lift)
    }

    /// - Parameters:
    ///   - progress: 0 at the start, 1 at the end.
    ///   - lift: how far the middle of the path rises above the straight line, in points.
    public static func point(from start: CGPoint, to end: CGPoint, progress: Double, lift: CGFloat) -> CGPoint {
        let clamped = CGFloat(min(max(progress, 0), 1))
        let control = Self.control(from: start, to: end, lift: lift)
        let inverse = 1 - clamped
        return CGPoint(
            x: inverse * inverse * start.x + 2 * inverse * clamped * control.x + clamped * clamped * end.x,
            y: inverse * inverse * start.y + 2 * inverse * clamped * control.y + clamped * clamped * end.y
        )
    }
}

/// The shape of a sheet whose corner is being pulled (spec 4.10).
///
/// Pulling a corner to a new place folds the paper along the line halfway
/// between where the corner was and where it is now. What is on the corner's
/// side of that line turns over and lies on the rest of the sheet.
public struct PaperFold: Equatable, Sendable {
    /// The part of the sheet that stays flat.
    public var kept: [CGPoint]
    /// Where the turned-over part was before the fold: now a hole in the sheet.
    public var hole: [CGPoint]
    /// The turned-over part, as it lies after the fold.
    public var flap: [CGPoint]

    /// - Returns: `nil` when the corner has not moved.
    public static func make(paper: CGRect, corner: CGPoint, pulledTo target: CGPoint) -> PaperFold? {
        let delta = CGPoint(x: target.x - corner.x, y: target.y - corner.y)
        let length = hypot(delta.x, delta.y)
        guard length > 0.5 else { return nil }
        let normal = CGPoint(x: delta.x / length, y: delta.y / length)
        let middle = CGPoint(x: (corner.x + target.x) / 2, y: (corner.y + target.y) / 2)
        func side(_ point: CGPoint) -> CGFloat {
            (point.x - middle.x) * normal.x + (point.y - middle.y) * normal.y
        }

        let sheet = [
            CGPoint(x: paper.minX, y: paper.minY), CGPoint(x: paper.maxX, y: paper.minY),
            CGPoint(x: paper.maxX, y: paper.maxY), CGPoint(x: paper.minX, y: paper.maxY),
        ]
        let kept = clip(sheet, keeping: { side($0) >= 0 }, side: side)
        let turned = clip(sheet, keeping: { side($0) <= 0 }, side: side)
        // Nothing turned, or the fold line missed the sheet and all of it would turn.
        guard turned.count >= 3, kept.count >= 3 else { return nil }
        let flap = turned.map { point -> CGPoint in
            let distance = side(point)
            return CGPoint(x: point.x - 2 * distance * normal.x, y: point.y - 2 * distance * normal.y)
        }
        return PaperFold(kept: kept, hole: turned, flap: flap)
    }

    /// Cuts a convex polygon with a line and returns the part on one side.
    private static func clip(
        _ polygon: [CGPoint],
        keeping isInside: (CGPoint) -> Bool,
        side: (CGPoint) -> CGFloat
    ) -> [CGPoint] {
        var result: [CGPoint] = []
        for index in polygon.indices {
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            let currentInside = isInside(current)
            if currentInside {
                result.append(current)
            }
            if currentInside != isInside(next) {
                let from = side(current)
                let to = side(next)
                let fraction = from / (from - to)
                result.append(CGPoint(
                    x: current.x + (next.x - current.x) * fraction,
                    y: current.y + (next.y - current.y) * fraction
                ))
            }
        }
        return result
    }
}

/// Decides what a released corner means (spec 4.10).
public struct PeelGesture: Equatable, Sendable {
    /// Pulled farther than this, in points, the sticker comes off.
    public var distanceThreshold: Double
    /// Released faster than this, in points per second, it comes off too.
    public var speedThreshold: Double

    public init(distanceThreshold: Double = 70, speedThreshold: Double = 800) {
        self.distanceThreshold = distanceThreshold
        self.speedThreshold = speedThreshold
    }

    public func comesOff(distance: Double, speed: Double) -> Bool {
        distance > distanceThreshold || speed > speedThreshold
    }

    /// Speed over the last moments of a drag, in points per second.
    /// - Parameter trail: positions with their times, oldest first.
    public static func releaseSpeed(trail: [(point: CGPoint, time: TimeInterval)], window: TimeInterval = 0.08) -> Double {
        guard let last = trail.last else { return 0 }
        guard let first = trail.first(where: { last.time - $0.time <= window }), last.time > first.time else { return 0 }
        return Double(hypot(last.point.x - first.point.x, last.point.y - first.point.y)) / (last.time - first.time)
    }
}
