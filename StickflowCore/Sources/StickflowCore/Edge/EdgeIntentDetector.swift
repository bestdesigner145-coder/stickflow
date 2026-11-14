// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Tells a cursor that came to the edge for the pad from one that is just passing (spec 4.1).
///
/// The pad shows in two steps. A cursor that rests in the zone makes it peek;
/// staying a little longer, or pushing on towards the edge, brings it out. A
/// fast cursor, a drag, or a cursor on its way to the next display does nothing.
public struct EdgeIntentDetector: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The pad shows its edge.
        case peek
        /// The pad is out.
        case open
    }

    public struct Rules: Equatable, Sendable {
        /// The cursor must be slower than this, in points per second.
        public var maxSpeed: Double
        /// Seconds of rest in the zone before the pad peeks.
        public var peekDelay: TimeInterval
        /// Further seconds before it comes out by itself.
        public var openDelay: TimeInterval
        /// Seconds away from the zone and the pad before it hides.
        public var leaveDelay: TimeInterval
        /// On: a cursor that entered the zone too fast is ignored until it leaves.
        /// Off: it may slow down inside the zone and still call the pad.
        public var fastEntryRejects: Bool

        public init(
            maxSpeed: Double,
            peekDelay: TimeInterval,
            openDelay: TimeInterval,
            leaveDelay: TimeInterval = 0.3,
            fastEntryRejects: Bool = false
        ) {
            self.maxSpeed = maxSpeed
            self.peekDelay = peekDelay
            self.openDelay = openDelay
            self.leaveDelay = leaveDelay
            self.fastEntryRejects = fastEntryRejects
        }

        /// An edge with nothing behind it.
        public static let free = Rules(maxSpeed: 600, peekDelay: 0.25, openDelay: 0.15)
        /// An edge shared with another display, or with the Dock on it.
        public static let strict = Rules(maxSpeed: 150, peekDelay: 0.45, openDelay: 0.2)
    }

    public struct Input: Equatable, Sendable {
        public var location: CGPoint
        public var isMouseDown: Bool
        /// Monotonic time in seconds.
        public var time: TimeInterval

        public init(location: CGPoint, isMouseDown: Bool = false, time: TimeInterval) {
            self.location = location
            self.isMouseDown = isMouseDown
            self.time = time
        }
    }

    /// Where the zone and the pad are right now.
    public struct Scene: Equatable, Sendable {
        public var zone: CGRect
        /// The visible part of the pad and what belongs to it; `nil` while it is hidden.
        public var padFrame: CGRect?
        /// Distance from the cursor to the edge, in points.
        public var distanceToEdge: CGFloat
        /// Something keeps the pad out, e.g. an open draft.
        public var holdsOpen: Bool

        public init(zone: CGRect, padFrame: CGRect? = nil, distanceToEdge: CGFloat, holdsOpen: Bool = false) {
            self.zone = zone
            self.padFrame = padFrame
            self.distanceToEdge = distanceToEdge
            self.holdsOpen = holdsOpen
        }
    }

    /// Speed is averaged over this many moves, so that one jittery event does not decide.
    private static let speedWindow = 5

    public private(set) var phase: Phase = .idle

    private var trail: [Input] = []
    private var wasInZone = false
    private var isRejected = false
    private var restingSince: TimeInterval?
    private var peekedAt: TimeInterval?
    private var distanceAtPeek: CGFloat = 0
    private var awaySince: TimeInterval?

    public init() {}

    /// True while a timer runs, so input must keep coming even if the mouse is still.
    public var needsContinuousInput: Bool {
        phase != .idle || restingSince != nil
    }

    /// Cursor speed in points per second, averaged over the last few moves.
    public var speed: Double {
        guard let first = trail.first, let last = trail.last, last.time > first.time else { return 0 }
        var path = 0.0
        for (previous, next) in zip(trail, trail.dropFirst()) {
            path += Double(hypot(next.location.x - previous.location.x, next.location.y - previous.location.y))
        }
        return path / (last.time - first.time)
    }

    /// Brings the pad out regardless of the cursor (hotkey, menu bar).
    public mutating func forceOpen() {
        phase = .open
        restingSince = nil
        awaySince = nil
    }

    /// Hides the pad at once.
    public mutating func reset() {
        phase = .idle
        restingSince = nil
        peekedAt = nil
        awaySince = nil
        isRejected = false
    }

    @discardableResult
    public mutating func update(_ input: Input, scene: Scene, rules: Rules) -> Phase {
        trail.append(input)
        if trail.count > Self.speedWindow + 1 {
            trail.removeFirst(trail.count - Self.speedWindow - 1)
        }
        let inZone = scene.zone.contains(input.location)
        defer { wasInZone = inZone }

        switch phase {
        case .idle:
            guard inZone, !input.isMouseDown else {
                // A pressed button means a drag or a selection; start over afterwards.
                restingSince = nil
                if !inZone { isRejected = false }
                return phase
            }
            let isSlow = speed < rules.maxSpeed
            if !wasInZone, !isSlow, rules.fastEntryRejects {
                isRejected = true
            }
            guard isSlow, !isRejected else {
                restingSince = nil
                return phase
            }
            let since = restingSince ?? input.time
            restingSince = since
            if input.time - since >= rules.peekDelay {
                phase = .peek
                restingSince = nil
                peekedAt = input.time
                distanceAtPeek = scene.distanceToEdge
                awaySince = nil
            }

        case .peek:
            let onPad = scene.padFrame?.contains(input.location) ?? false
            if scene.holdsOpen {
                phase = .open
                awaySince = nil
            } else if inZone || onPad {
                awaySince = nil
                let waited = input.time - (peekedAt ?? input.time) >= rules.openDelay
                let pushedOn = scene.distanceToEdge <= distanceAtPeek - 1
                if waited || pushedOn || (onPad && !inZone) {
                    phase = .open
                }
            } else {
                hideIfAwayLongEnough(at: input.time, rules: rules)
            }

        case .open:
            let onPad = scene.padFrame?.contains(input.location) ?? false
            if scene.holdsOpen || inZone || onPad {
                awaySince = nil
            } else {
                hideIfAwayLongEnough(at: input.time, rules: rules)
            }
        }
        return phase
    }

    private mutating func hideIfAwayLongEnough(at time: TimeInterval, rules: Rules) {
        let since = awaySince ?? time
        awaySince = since
        if time - since >= rules.leaveDelay {
            phase = .idle
            awaySince = nil
            peekedAt = nil
        }
    }
}
