// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// The only global hotkey that is set by default (spec 5.4): quick input, ⌘⌥↩.
    static let quickInput = Self("quickInput", default: .init(.return, modifiers: [.command, .option]))
}

/// Registers global hotkeys. Uses `RegisterEventHotKey` under the hood, so no
/// Accessibility permission is needed (spec 5.3).
@MainActor
final class HotkeyService {
    func start(onQuickInput: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .quickInput) {
            MainActor.assumeIsolated {
                onQuickInput()
            }
        }
    }
}
