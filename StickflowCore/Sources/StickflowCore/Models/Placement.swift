// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// A point stored without CoreGraphics so the JSON stays stable across platforms.
public struct StickerPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Where a sticker lives on screen.
///
/// Positions are remembered per display configuration (spec 4.5), so a sticker
/// returns to its old spot when a monitor is plugged back in.
public struct Placement: Codable, Equatable, Sendable {
    /// `DisplayKey` of the display the sticker was last dropped on.
    /// `nil` means "the sticker display chosen in settings".
    public var displayKey: String?

    /// Top-left corner of the paper per `DisplayKey`, as an offset from the
    /// display's top-left corner with y growing downwards. A missing entry means
    /// "use the default anchor".
    public var positions: [String: StickerPoint]

    /// Stack membership (spec 4.9). Unused until stage 2.
    public var stackID: UUID?
    public var stackIndex: Int

    public init(
        displayKey: String? = nil,
        positions: [String: StickerPoint] = [:],
        stackID: UUID? = nil,
        stackIndex: Int = 0
    ) {
        self.displayKey = displayKey
        self.positions = positions
        self.stackID = stackID
        self.stackIndex = stackIndex
    }
}

/// Identifies a display together with its resolution: `"<uuid>@<width>x<height>"`.
///
/// The UUID comes from `CGDisplayCreateUUIDFromDisplayID`; unlike
/// `CGDirectDisplayID` it survives reconnects and reboots.
public enum DisplayKey {
    public static func make(uuid: String, width: Double, height: Double) -> String {
        "\(uuid)@\(Int(width.rounded()))x\(Int(height.rounded()))"
    }

    /// The UUID part of a key, or `nil` when the key is malformed.
    public static func uuid(from key: String) -> String? {
        guard let separator = key.lastIndex(of: "@") else { return nil }
        let uuid = key[key.startIndex..<separator]
        return uuid.isEmpty ? nil : String(uuid)
    }
}
