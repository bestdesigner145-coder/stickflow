// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import CoreGraphics
import Foundation
import StickflowCore

/// One display, as much of it as stickers need.
struct ScreenInfo: Equatable, Sendable {
    /// Stable UUID of the display, or `nil` when the system cannot provide one.
    /// `CGDirectDisplayID` may change between connections, so it is not used.
    let uuid: String?
    let name: String
    /// The whole display in global coordinates (origin at the bottom left).
    let frame: CGRect
    /// The display without the menu bar and the Dock.
    let visibleFrame: CGRect

    /// Key under which sticker positions for this display and resolution are stored.
    var key: String {
        DisplayKey.make(uuid: uuid ?? "unknown-\(name)", width: frame.width, height: frame.height)
    }
}

/// The connected displays, behind a protocol so that tests can lay them out as they like (spec 17.4).
@MainActor
protocol ScreenGeometry: AnyObject {
    /// Connected displays; the one with the menu bar comes first.
    var screens: [ScreenInfo] { get }
}

extension ScreenGeometry {
    /// The screen that holds the menu bar.
    var menuBarScreen: ScreenInfo? {
        screens.first
    }

    func screen(forUUID uuid: String) -> ScreenInfo? {
        screens.first { $0.uuid == uuid }
    }

    /// Screen new stickers appear on: the preferred one if connected, else the menu bar screen.
    func stickerScreen(preferredUUID: String?) -> ScreenInfo? {
        if let preferredUUID, let preferred = screen(forUUID: preferredUUID) {
            return preferred
        }
        return menuBarScreen
    }

    /// Screen that contains most of `rect`, if any.
    func screen(containing rect: CGRect) -> ScreenInfo? {
        let all = screens
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = all.first(where: { $0.frame.contains(center) }) {
            return hit
        }
        var best: (screen: ScreenInfo, area: CGFloat)?
        for screen in all {
            let overlap = screen.frame.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) {
                best = (screen, area)
            }
        }
        return best?.screen
    }
}

/// A made-up layout that never changes, for tests and `--ui-testing`.
@MainActor
final class FixedScreenGeometry: ScreenGeometry {
    let screens: [ScreenInfo]

    init(screens: [ScreenInfo]) {
        self.screens = screens
    }

    /// One 1440×900 display with a 25 pt menu bar and no Dock.
    static func single() -> FixedScreenGeometry {
        FixedScreenGeometry(screens: [
            ScreenInfo(
                uuid: "00000000-0000-4000-8000-00000000D001",
                name: "Test Display",
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
            ),
        ])
    }
}
