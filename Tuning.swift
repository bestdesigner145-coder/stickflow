// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
import Observation
import QuartzCore

/// Every tunable number of the app lives here (spec rule 0.2).
///
/// Values are the starting points from the spec. Debug builds expose them in the
/// "Tuning" panel; code reads them at the moment of use, so a slider takes effect
/// immediately.
@MainActor
@Observable
final class Tuning {
    // MARK: Sticker geometry (4.6)

    var glueStripHeight: Double = 14
    var cornerZoneSize: Double = 28
    var widthSmall: Double = 200
    var widthMedium: Double = 232
    var widthLarge: Double = 280
    /// Tallest a sticker gets at rest; longer text fades out at the bottom.
    var maxPaperHeight: Double = 280
    var minPaperHeight: Double = 52
    var paperCornerRadius: Double = 3
    /// Transparent border around the paper where the shadow is drawn.
    var shadowMargin: Double = 40

    // MARK: Default anchor and moving (4.5)

    var anchorInsetRight: Double = 20
    /// 112 ≈ window title bar 28 + toolbar 52 + gap 32.
    var anchorInsetTop: Double = 112
    var magnetDistance: Double = 12
    /// Until stacks arrive (stage 2), stickers at the default anchor are cascaded by this offset.
    var cascadeOffset: Double = 18

    // MARK: Rest and fading under the cursor (4.7)

    var restTextOpacity: Double = 0.92
    var doneTextOpacity: Double = 0.45
    var fadeDelay: Double = 0.120
    var fadedOpacity: Double = 0.2
    var fadeOutDuration: Double = 0.150
    var fadeInDuration: Double = 0.200

    // MARK: Edit mode (4.6) and editing (4.8)

    var editModeInDuration: Double = 0.100
    var editModeOutDuration: Double = 0.150
    /// How long the sticker stays interactive after the edit key is released.
    var editKeyReleaseGrace: Double = 0.150
    var pointerPollInterval: Double = 1.0 / 60.0
    /// The edit key is watched while the cursor is over the sticker or this close to it.
    var editKeyProximity: Double = 8
    /// Polling starts a little earlier than the edit-key zone so fading feels instant.
    var pointerPollProximity: Double = 24
    var editingIdleTimeout: Double = 20
    var hintDwell: Double = 1.0
    var hintMaxShows: Int = 5
    var hintDuration: Double = 2.5

    // MARK: Shadows (6.2) — CSS-like: y offset, blur, opacity

    var restShadowOffset: Double = 1
    var restShadowBlur: Double = 2
    var restShadowOpacity: Double = 0.10
    var liftedShadowOffset: Double = 12
    var liftedShadowBlur: Double = 24
    var liftedShadowOpacity: Double = 0.18
    var darkShadowMultiplier: Double = 1.6

    // MARK: Behaviour switches for hands-on comparison (spec rule 0.3)

    /// Off: holding the edit key anywhere and moving onto the sticker enters edit mode.
    /// On: the key must be pressed while the cursor is already over the sticker.
    var editRequiresKeyPressOverSticker = false
    /// Do not enter edit mode while a mouse button is held (⌥-drag in Figma copies a layer).
    var suppressEditWhileMouseDown = true
    /// Off: "show over full-screen apps" toggles `.fullScreenAuxiliary`.
    /// On: the spec variant — the behaviour is always set and the setting raises the window level.
    var fullscreenUsesWindowLevel = false
    /// Kind of the line created by Return after the title: a task (on) or plain text (off).
    var newLineAfterTitleIsTodo = true

    // MARK: Animation (6.7)

    /// 1 = normal speed, 3 and 10 slow everything down for inspection.
    var animationSlowdown: Double = 1

    func scaled(_ duration: Double) -> Double {
        duration * max(animationSlowdown, 0.01)
    }
}

/// Cubic Bézier curves from the animation tokens table (spec 6.7).
struct MotionCurve: Sendable {
    let c1x: Float
    let c1y: Float
    let c2x: Float
    let c2y: Float

    var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: c1x, c1y, c2x, c2y)
    }

    /// Appearing, reacting to an action.
    static let easeOut = MotionCurve(c1x: 0.23, c1y: 1, c2x: 0.32, c2y: 1)
    /// Moving across the screen.
    static let easeInOut = MotionCurve(c1x: 0.77, c1y: 0, c2x: 0.175, c2y: 1)
    /// Pad, edge panel and history sliding out.
    static let drawer = MotionCurve(c1x: 0.32, c1y: 0.72, c2x: 0, c2y: 1)
    /// Colour, texture, highlight.
    static let ease = MotionCurve(c1x: 0.25, c1y: 0.1, c2x: 0.25, c2y: 1)
}
