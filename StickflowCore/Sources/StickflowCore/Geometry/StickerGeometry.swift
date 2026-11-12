// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics // CGRect members such as `maxX` live here, not in Foundation
#endif

/// Placement maths in AppKit screen coordinates (origin bottom-left, y grows upwards).
public enum StickerGeometry {
    /// Top-right corner of the default anchor: the upper right of the work area,
    /// below typical window title bars and toolbars (spec 4.5).
    public static func defaultTopRight(visibleFrame: CGRect, insetRight: CGFloat, insetTop: CGFloat) -> CGPoint {
        CGPoint(x: visibleFrame.maxX - insetRight, y: visibleFrame.maxY - insetTop)
    }

    /// Moves `frame` the minimum distance needed to fit inside `bounds`.
    /// A frame larger than `bounds` is aligned to the top-left corner.
    public static func clamped(_ frame: CGRect, within bounds: CGRect) -> CGRect {
        var result = frame
        if result.width >= bounds.width {
            result.origin.x = bounds.minX
        } else {
            result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
        }
        if result.height >= bounds.height {
            result.origin.y = bounds.maxY - result.height
        } else {
            result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
        }
        return result
    }

    /// Snaps `frame` to the edges of `bounds` and of `others` when an edge is
    /// closer than `distance` (spec 4.5: magnet, 12 pt).
    public static func snapped(_ frame: CGRect, within bounds: CGRect, others: [CGRect], distance: CGFloat) -> CGRect {
        guard distance > 0 else { return frame }

        var xTargets: [CGFloat] = [bounds.minX - frame.minX, bounds.maxX - frame.maxX]
        var yTargets: [CGFloat] = [bounds.minY - frame.minY, bounds.maxY - frame.maxY]

        for other in others {
            let nearVertically = frame.maxY >= other.minY - distance && frame.minY <= other.maxY + distance
            let nearHorizontally = frame.maxX >= other.minX - distance && frame.minX <= other.maxX + distance
            if nearVertically {
                xTargets.append(other.minX - frame.minX) // left edges aligned
                xTargets.append(other.maxX - frame.maxX) // right edges aligned
                xTargets.append(other.maxX - frame.minX) // sits to the right of `other`
                xTargets.append(other.minX - frame.maxX) // sits to the left of `other`
            }
            if nearHorizontally {
                yTargets.append(other.minY - frame.minY)
                yTargets.append(other.maxY - frame.maxY)
                yTargets.append(other.maxY - frame.minY)
                yTargets.append(other.minY - frame.maxY)
            }
        }

        var result = frame
        if let dx = smallestShift(in: xTargets, within: distance) {
            result.origin.x += dx
        }
        if let dy = smallestShift(in: yTargets, within: distance) {
            result.origin.y += dy
        }
        return result
    }

    private static func smallestShift(in shifts: [CGFloat], within distance: CGFloat) -> CGFloat? {
        var best: CGFloat?
        for shift in shifts where abs(shift) <= distance {
            if let current = best {
                if abs(shift) < abs(current) { best = shift }
            } else {
                best = shift
            }
        }
        return best
    }
}
