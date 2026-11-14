// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// The real displays, read from AppKit.
@MainActor
final class DisplayService: ScreenGeometry {
    /// `NSScreen.screens.first` is the screen with the menu bar. `NSScreen.main`
    /// is the screen of the key window, which is not what stickers need.
    var screens: [ScreenInfo] {
        NSScreen.screens.map { screen in
            ScreenInfo(
                uuid: Self.uuid(for: screen),
                name: screen.localizedName,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
    }

    private static func uuid(for screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = unmanaged.takeRetainedValue()
        guard let string = CFUUIDCreateString(nil, uuid) else { return nil }
        return string as String
    }
}
