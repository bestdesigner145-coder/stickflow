// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// Where the cursor is and whether a mouse button is down (spec 17.4).
@MainActor
protocol MouseSource: AnyObject {
    /// Cursor position in screen coordinates.
    var location: CGPoint { get }
    var isButtonDown: Bool { get }
}

/// Which modifier keys are held (spec 17.4).
@MainActor
protocol ModifierSource: AnyObject {
    var modifiers: NSEvent.ModifierFlags { get }
}

/// The real mouse and keyboard. Reading them needs no permission (spec 5.3).
@MainActor
final class SystemPointerSource: MouseSource, ModifierSource {
    var location: CGPoint { NSEvent.mouseLocation }
    var isButtonDown: Bool { NSEvent.pressedMouseButtons != 0 }
    var modifiers: NSEvent.ModifierFlags { NSEvent.modifierFlags }
}

/// A pointer that is wherever a test puts it.
@MainActor
final class ScriptedPointerSource: MouseSource, ModifierSource {
    var location = CGPoint.zero
    var isButtonDown = false
    var modifiers: NSEvent.ModifierFlags = []
}
