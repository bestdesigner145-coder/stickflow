// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// A side of the screen the pad can live at.
public enum ScreenSide: String, Sendable, CaseIterable {
    case left
    case right
}

/// A display as the edge logic needs it.
public struct ScreenLayout: Equatable, Sendable {
    /// The whole display in global coordinates.
    public var frame: CGRect
    /// The display without the menu bar and the Dock.
    public var visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// The screen edge the pad is called from (spec 4.1).
///
/// A screen edge is an infinitely deep target: the cursor runs into it and stops.
/// That only holds when nothing is behind the edge. Next to another display the
/// cursor passes through, and an edge with the Dock already has a job.
public struct CallEdge: Equatable, Sendable {
    /// What the user asked for in settings.
    public enum Preference: String, Sendable, CaseIterable {
        case automatic
        case left
        case right
    }

    public var side: ScreenSide
    /// The edge is not free (another display or the Dock is there), so the zone
    /// is deeper and asks for a slower, longer stop.
    public var isStrict: Bool

    public init(side: ScreenSide, isStrict: Bool) {
        self.side = side
        self.isStrict = isStrict
    }

    /// Picks the edge: the right one if it is free, otherwise the left one,
    /// otherwise the right one with strict thresholds.
    public static func choose(
        for screen: ScreenLayout,
        others: [ScreenLayout],
        preference: Preference = .automatic
    ) -> CallEdge {
        func isTaken(_ side: ScreenSide) -> Bool {
            hasDock(on: side, of: screen) || others.contains { borders($0, side: side, of: screen) }
        }
        switch preference {
        case .left:
            return CallEdge(side: .left, isStrict: isTaken(.left))
        case .right:
            return CallEdge(side: .right, isStrict: isTaken(.right))
        case .automatic:
            if !isTaken(.right) { return CallEdge(side: .right, isStrict: false) }
            if !isTaken(.left) { return CallEdge(side: .left, isStrict: false) }
            return CallEdge(side: .right, isStrict: true)
        }
    }

    private static func hasDock(on side: ScreenSide, of screen: ScreenLayout) -> Bool {
        switch side {
        case .left: screen.visibleFrame.minX - screen.frame.minX > 1
        case .right: screen.frame.maxX - screen.visibleFrame.maxX > 1
        }
    }

    private static func borders(_ other: ScreenLayout, side: ScreenSide, of screen: ScreenLayout) -> Bool {
        let overlapsVertically = other.frame.minY < screen.frame.maxY && other.frame.maxY > screen.frame.minY
        guard overlapsVertically else { return false }
        switch side {
        case .left: return abs(other.frame.maxX - screen.frame.minX) <= 1
        case .right: return abs(other.frame.minX - screen.frame.maxX) <= 1
        }
    }

    // MARK: Geometry

    /// The invisible area at the edge where a resting cursor calls the pad.
    /// - Parameters:
    ///   - depth: how far the area reaches into the screen, in points.
    ///   - verticalRange: its extent as fractions of the visible height, from the top.
    public func zone(on screen: ScreenLayout, depth: CGFloat, verticalRange: ClosedRange<CGFloat>) -> CGRect {
        let visible = screen.visibleFrame
        let top = visible.maxY - visible.height * verticalRange.lowerBound
        let bottom = visible.maxY - visible.height * verticalRange.upperBound
        let originX = side == .right ? screen.frame.maxX - depth : screen.frame.minX
        return CGRect(x: originX, y: bottom, width: depth, height: top - bottom)
    }

    /// How far `point` is from the edge, in points; zero at the edge.
    public func distance(of point: CGPoint, on screen: ScreenLayout) -> CGFloat {
        side == .right ? screen.frame.maxX - point.x : point.x - screen.frame.minX
    }
}
