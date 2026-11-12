// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// Entry point. Stickflow is an AppKit agent app: no Dock icon, no main window,
/// only a menu bar item and the sticker panels (spec 5.1).
@main
@MainActor
enum StickflowMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        // `NSApplication.delegate` is weak; keep the delegate alive for the whole run.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
