// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// How a sticker reacts to the pointer and the edit key (spec 4.6, 4.7).
///
/// At rest a sticker lets every click through. Under a still cursor it fades.
/// With the edit key held over it, it becomes paper one can work with. A click
/// on its text starts editing, which lasts until the editor ends it.
///
/// The machine knows nothing about windows: it is fed what the pointer does and
/// answers with the mode to show. That keeps it testable without a screen.
public struct StickerStateMachine: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// Click-through, translucent paper.
        case rest
        /// Click-through and almost invisible: the cursor is over the sticker.
        case faded
        /// The edit key is held over the sticker: opaque, takes clicks.
        case editMode
        /// The text has keyboard focus.
        case editing
    }

    /// Values that come from settings and `Tuning`.
    public struct Rules: Equatable, Sendable {
        public var fadeEnabled: Bool
        /// Seconds the cursor rests on the sticker before it starts to fade. Zero by
        /// the spec (4.7): a pause before an animation reads as lag.
        public var fadeDelay: TimeInterval
        /// Seconds edit mode outlives the key or the cursor leaving.
        public var releaseGrace: TimeInterval
        /// Seconds of hovering before the "hold ⌥ to edit" hint.
        public var hintDwell: TimeInterval
        /// The edit key does nothing while a mouse button is down (a drag in the app underneath).
        public var suppressEditWhileMouseDown: Bool
        /// The key only counts when pressed with the cursor already at the sticker.
        public var keyMustBePressedAtSticker: Bool

        public init(
            fadeEnabled: Bool = true,
            fadeDelay: TimeInterval = 0,
            releaseGrace: TimeInterval = 0.15,
            hintDwell: TimeInterval = 1,
            suppressEditWhileMouseDown: Bool = true,
            keyMustBePressedAtSticker: Bool = false
        ) {
            self.fadeEnabled = fadeEnabled
            self.fadeDelay = fadeDelay
            self.releaseGrace = releaseGrace
            self.hintDwell = hintDwell
            self.suppressEditWhileMouseDown = suppressEditWhileMouseDown
            self.keyMustBePressedAtSticker = keyMustBePressedAtSticker
        }
    }

    /// One look at the pointer and the keyboard.
    public struct Input: Equatable, Sendable {
        /// The cursor is on the paper.
        public var isOver: Bool
        /// The cursor is on the paper or within a few points of it.
        public var isNear: Bool
        public var isEditKeyDown: Bool
        public var isMouseDown: Bool
        /// The sticker is inside the cursor's halo (spec 4.7): every sticker near
        /// the cursor fades, not only the one under it.
        public var isInHalo: Bool
        /// Monotonic time in seconds.
        public var time: TimeInterval

        /// - Parameter isInHalo: defaults to `isOver`, i.e. a halo of no size.
        public init(
            isOver: Bool,
            isNear: Bool,
            isEditKeyDown: Bool,
            isMouseDown: Bool = false,
            isInHalo: Bool? = nil,
            time: TimeInterval
        ) {
            self.isOver = isOver
            self.isNear = isNear
            self.isEditKeyDown = isEditKeyDown
            self.isMouseDown = isMouseDown
            self.isInHalo = isInHalo ?? isOver
            self.time = time
        }
    }

    /// What the caller should do besides showing the new mode.
    public struct Outcome: Equatable, Sendable {
        public var hidesHint = false
        public var showsHint = false

        public init(hidesHint: Bool = false, showsHint: Bool = false) {
            self.hidesHint = hidesHint
            self.showsHint = showsHint
        }
    }

    public private(set) var mode: Mode = .rest

    /// When the cursor's halo reached the sticker; drives the fade delay.
    private var hoverSince: TimeInterval?
    /// When the cursor came onto the paper itself; drives the hint.
    private var overSince: TimeInterval?
    /// When edit mode ends after the key was released or the cursor left.
    private var releaseDeadline: TimeInterval?
    private var wasNear = false
    /// False when the edit key was already down as the cursor arrived (see `Rules`).
    private var isArmed = true
    private var hintShownForThisHover = false

    public init() {}

    /// True while a timer is running or the sticker is in a state the pointer can end,
    /// so the caller must keep sending input even if the mouse is still.
    public var needsContinuousInput: Bool {
        mode == .faded || mode == .editMode || hoverSince != nil || overSince != nil || releaseDeadline != nil
    }

    /// Feeds the machine one look at the pointer.
    public mutating func pointerMoved(_ input: Input, rules: Rules) -> Outcome {
        if !input.isEditKeyDown {
            isArmed = true
        } else if input.isNear, !wasNear, rules.keyMustBePressedAtSticker {
            isArmed = false
        }
        wasNear = input.isNear

        switch mode {
        case .editing:
            return Outcome()

        case .editMode:
            if input.isEditKeyDown, input.isNear {
                releaseDeadline = nil
                return Outcome()
            }
            let deadline = releaseDeadline ?? input.time + rules.releaseGrace
            releaseDeadline = deadline
            if input.time >= deadline {
                releaseDeadline = nil
                hoverSince = (input.isInHalo || input.isOver) ? input.time : nil
                overSince = input.isOver ? input.time : nil
                // The user has just used the key; no need to teach it again.
                hintShownForThisHover = true
                mode = .rest
            }
            return Outcome()

        case .rest, .faded:
            let isBlockedByMouse = rules.suppressEditWhileMouseDown && input.isMouseDown
            if input.isEditKeyDown, input.isNear, isArmed, !isBlockedByMouse {
                hoverSince = nil
                mode = .editMode
                return Outcome(hidesHint: true)
            }
            // The hint is about the sticker under the cursor; the fade is about the halo.
            if input.isOver {
                overSince = overSince ?? input.time
            } else {
                overSince = nil
                hintShownForThisHover = false
            }
            guard input.isInHalo || input.isOver else {
                hoverSince = nil
                mode = .rest
                return Outcome()
            }
            let since = hoverSince ?? input.time
            hoverSince = since

            if rules.fadeEnabled {
                if mode == .rest, input.time - since >= rules.fadeDelay { mode = .faded }
            } else {
                mode = .rest
            }
            if let overSince, !input.isEditKeyDown, !hintShownForThisHover, input.time - overSince >= rules.hintDwell {
                hintShownForThisHover = true
                return Outcome(showsHint: true)
            }
            return Outcome()
        }
    }

    /// The text took keyboard focus.
    public mutating func beginEditing() {
        hoverSince = nil
        overSince = nil
        releaseDeadline = nil
        mode = .editing
    }

    /// Editing is over; the sticker is click-through again.
    public mutating func endEditing() {
        hoverSince = nil
        overSince = nil
        releaseDeadline = nil
        mode = .rest
    }

    /// Forgets a pending end of edit mode, e.g. after a menu or a drag during
    /// which the pointer was not watched.
    public mutating func cancelPendingRelease() {
        releaseDeadline = nil
    }
}
