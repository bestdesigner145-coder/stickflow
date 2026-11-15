// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// The cursor's halo (spec 4.7): an invisible circle around the cursor. Every
/// sticker it touches fades, the nearer the stronger, so that a spot covered by
/// several stickers can be seen through all of them.
public struct HaloFade: Equatable, Sendable {
    /// Radius of the halo, in points. Beyond it a sticker does not fade.
    public var radius: Double
    /// Within this distance a sticker fades all the way.
    public var fullFadeWithin: Double
    /// Opacity of a sticker that has faded all the way.
    public var fadedOpacity: Double

    public init(radius: Double = 140, fullFadeWithin: Double = 40, fadedOpacity: Double = 0.2) {
        self.radius = radius
        self.fullFadeWithin = fullFadeWithin
        self.fadedOpacity = fadedOpacity
    }

    /// Distance from `point` to the nearest point of `rect`; zero inside it.
    public static func distance(from point: CGPoint, to rect: CGRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return Double(hypot(dx, dy))
    }

    public func reaches(distance: Double) -> Bool {
        distance < radius
    }

    /// Opacity of a sticker whose nearest point is `distance` from the cursor:
    /// fully faded up close, untouched at the rim, smooth in between.
    public func opacity(distance: Double) -> Double {
        guard distance > fullFadeWithin else { return fadedOpacity }
        guard distance < radius, radius > fullFadeWithin else { return 1 }
        let progress = (distance - fullFadeWithin) / (radius - fullFadeWithin)
        let eased = progress * progress * (3 - 2 * progress) // no kink at either end
        return fadedOpacity + (1 - fadedOpacity) * eased
    }
}
