// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

/// Identifies displays in a way that survives reconnects.
///
/// `CGDirectDisplayID` may change between connections, so positions are keyed by
/// the display UUID plus its resolution (see `DisplayKey`).
@MainActor
final class DisplayService {
    /// Stable UUID of the screen, or `nil` when the system cannot provide one.
    func uuid(for screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = unmanaged.takeRetainedValue()
        guard let string = CFUUIDCreateString(nil, uuid) else { return nil }
        return string as String
    }

    /// Key under which sticker positions for this screen are stored.
    func key(for screen: NSScreen) -> String {
        let identifier = uuid(for: screen) ?? "unknown-\(screen.localizedName)"
        return DisplayKey.make(uuid: identifier, width: screen.frame.width, height: screen.frame.height)
    }

    func screen(forUUID uuid: String) -> NSScreen? {
        NSScreen.screens.first { self.uuid(for: $0) == uuid }
    }

    /// The screen that holds the menu bar. `NSScreen.main` is the screen of the
    /// key window, which is not what we want.
    var menuBarScreen: NSScreen? {
        NSScreen.screens.first
    }

    /// Screen new stickers appear on: the preferred one if connected, else the menu bar screen.
    func stickerScreen(preferredUUID: String?) -> NSScreen? {
        if let preferredUUID, let preferred = screen(forUUID: preferredUUID) {
            return preferred
        }
        return menuBarScreen
    }

    /// Screen that contains most of `rect`, if any.
    func screen(containing rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return hit
        }
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in NSScreen.screens {
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
