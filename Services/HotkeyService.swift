// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// The only global hotkey that is set by default (spec 5.4): quick input, ⌘⌥↩.
    static let quickInput = Self("quickInput", default: .init(.return, modifiers: [.command, .option]))
    /// Show or hide every sticker. Not set by default; the user assigns it.
    static let toggleStickers = Self("toggleStickers")
    /// ⌘Z while the "Sticker peeled off · Restore" toast is up (spec 4.10).
    /// Registered only for those few seconds, see `HotkeyService.setUndoPeelArmed`.
    static let undoPeel = Self("undoPeel")
}

/// Registers global hotkeys. Uses `RegisterEventHotKey` under the hood, so no
/// Accessibility permission is needed (spec 5.3).
@MainActor
final class HotkeyService {
    func start(
        onQuickInput: @escaping @MainActor () -> Void,
        onToggleStickers: @escaping @MainActor () -> Void,
        onUndoPeel: @escaping @MainActor () -> Void
    ) {
        // The app may have quit while the temporary ⌘Z was registered. Never start with it.
        setUndoPeelArmed(false)

        KeyboardShortcuts.onKeyDown(for: .quickInput) {
            MainActor.assumeIsolated {
                onQuickInput()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .toggleStickers) {
            MainActor.assumeIsolated {
                onToggleStickers()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .undoPeel) {
            MainActor.assumeIsolated {
                onUndoPeel()
            }
        }
    }

    /// Takes ⌘Z as a global hotkey, or gives it back.
    ///
    /// A global hotkey wins over the app in front, so a permanent ⌘Z would break
    /// Undo everywhere. It is held only while the "Restore" toast is on offer.
    func setUndoPeelArmed(_ armed: Bool) {
        let shortcut: KeyboardShortcuts.Shortcut? = armed
            ? KeyboardShortcuts.Shortcut(.z, modifiers: [.command])
            : nil
        guard KeyboardShortcuts.getShortcut(for: .undoPeel) != shortcut else { return }
        KeyboardShortcuts.setShortcut(shortcut, for: .undoPeel)
    }
}
