// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import Foundation
import Observation
import QuartzCore
import StickflowCore

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
    /// Spec 18.6: 260 / 320 / 400; a title of 2–4 words fits one line at M.
    var widthSmall: Double = 260
    var widthMedium: Double = 320
    var widthLarge: Double = 400
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
    var fadedOpacity: Double = 0.2
    /// The cursor's halo: every sticker within this distance of the cursor fades,
    /// fully within `haloCore`, less and less towards the rim.
    var haloRadius: Double = 140
    var haloCore: Double = 40
    // The fade starts the moment the cursor is over the sticker: no pause before
    // an animation, either at once or smoothly (spec 4.7, 6.7).
    var fadeOutDuration: Double = 0.180
    var fadeInDuration: Double = 0.220

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

    // MARK: Appearing, peeling, theme change, toast (6.7)

    var appearDuration: Double = 0.200
    var appearStartScale: Double = 0.96
    var peelDuration: Double = 0.240
    var peelEndScale: Double = 0.3
    /// With "Reduce motion" on, movement is replaced by a fade of this length.
    var reducedMotionFade: Double = 0.150
    var themeTransitionDuration: Double = 0.250
    var toastDuration: Double = 4.0
    var toastInDuration: Double = 0.200
    var toastOutDuration: Double = 0.150
    var toastShift: Double = 8

    // MARK: Call zone and pad (4.1, 4.2)

    /// How deep the zone reaches into the screen: a free edge, and one shared with a display or the Dock.
    var zoneDepthFree: Double = 4
    var zoneDepthStrict: Double = 10
    /// The zone's extent as fractions of the visible height, from the top.
    var zoneTop: Double = 0.35
    var zoneBottom: Double = 0.65
    var zoneMaxSpeedFree: Double = 600
    var zoneMaxSpeedStrict: Double = 150
    var zonePeekDelayFree: Double = 0.25
    var zonePeekDelayStrict: Double = 0.45
    var zoneOpenDelayFree: Double = 0.15
    var zoneOpenDelayStrict: Double = 0.20
    var zoneLeaveDelay: Double = 0.30
    var tabWidth: Double = 4
    var tabHeight: Double = 56
    var tabOpacity: Double = 0.35
    var padSize: Double = 112
    /// The label on the pad; it shrinks down to the minimum until its longest word fits.
    var padLabelFontSize: Double = 20
    var padLabelMinFontSize: Double = 13
    var padPeekReach: Double = 28
    var padOpenReach: Double = 96
    var padPeekRotation: Double = -6
    var padPeekDuration: Double = 0.18
    var padOpenDuration: Double = 0.22
    var padHideDuration: Double = 0.18
    /// Fix K1: the pad goes back the way it came out, the `drawer` curve played
    /// backwards (slow start, fast end). Played forwards, the curve covers most
    /// of the way in its first frames, and the pad seems to vanish at once.
    var padHideCurveReversed = true
    /// "Reduce motion": the pad does not travel, it fades in and out (spec 6.7, fix K1).
    var padReduceMotionFade: Double = 0.15
    /// The pad's shadow: wide and faint (fix H5).
    var padShadowRadius: Double = 20
    var padShadowOpacity: Double = 0.2
    var padShadowOffset: Double = 6
    /// Opacity in the middle of the oval behind the pad.
    var padGlowOpacity: Double = 0.1

    // MARK: Draft (4.3)

    var draftMinHeight: Double = 160
    var draftMaxHeight: Double = 360
    var draftGap: Double = 12
    var draftFromPadDuration: Double = 0.22
    var draftFromHotkeyDuration: Double = 0.12
    var draftFromPadStartScale: Double = 0.96
    var draftFromHotkeyStartScale: Double = 0.98

    // MARK: Sticking (4.4) and peeling by the corner (4.10)

    /// Spec 6.7: 280 ms, easeOut: a quick start and a soft landing.
    var flightDuration: Double = 0.28
    /// A sticker that flies or is peeled is a picture in the effects overlay. For
    /// this long the picture and the sticker's own window overlap when one takes
    /// over from the other, so that there is never a frame with neither.
    var spriteHandoverDuration: Double = 0.06
    /// How far the middle of the flight rises above the straight line.
    var flightLift: Double = 60
    var flightScale: Double = 1.03
    /// How long the sticker takes to grow to that scale as it lifts off.
    var flightLiftOffDuration: Double = 0.1
    var impactDuration: Double = 0.22
    /// The squash at the moment of impact: 1.03 → this → 1.
    var impactSquash: Double = 0.985
    var airRingDuration: Double = 0.26
    var airRingReach: Double = 10
    var airRingOpacity: Double = 0.25
    /// The square at the bottom right the sticker is peeled by.
    var peelCornerSize: Double = 28
    /// How far the corner is folded when the edit key is held, as a hint.
    var peelCornerHint: Double = 9
    var peelDistance: Double = 70
    var peelSpeed: Double = 800
    var peelGestureDuration: Double = 0.28
    var peelRotation: Double = 8
    var peelSnapBackDuration: Double = 0.4
    var peelSnapBackBounce: Double = 0.2

    // MARK: Screen sharing (5.2)

    /// How often the app asks whether the screen is being captured.
    var captureWatchInterval: Double = 0.1
    /// How long after the capture ends the stickers come back.
    var captureReturnDelay: Double = 1.0

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
    /// On: keyboard focus goes back through an invisible helper panel and the sticker
    /// never leaves the screen. Off: the first implementation, which hides and shows
    /// the sticker and makes it blink.
    var focusReturnUsesHelperPanel = true
    /// Off (spec 5.1): `.stationary`. On: `.transient`, which floats across Spaces
    /// and is hidden in Mission Control. For comparing how stickers behave when
    /// the desktop changes.
    var spacesBehaviorTransient = false
    /// Overrides the system's "Reduce motion" for tests: `true` or `false` forces
    /// it, `nil` follows the system.
    var forcedReduceMotion: Bool?

    /// "Reduce motion" is on: movement and rotation become a short cross-fade (spec 6.7).
    var reduceMotion: Bool {
        forcedReduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// On: a cursor that flew into the zone is ignored until it leaves and comes
    /// back slowly. Off: it may stop in the zone and still call the pad.
    var zoneRejectsFastEntry = false

    /// Rules (spec 8.1): read "в три" said without "утра" or "дня" as 15:00, the
    /// way the spec's example does. Off (author, 15.11.2026): no guessing, such
    /// an hour stays in the text as it was said.
    var rulesAssumeAfternoon = false

    // MARK: Structuring (spec 8, 4.3)

    /// How long the draft shows the result, highlighted, before it is stuck.
    var structuredPreviewDuration: Double = 1.2
    /// The built-in model, the first time: it loads and reads its rules (spec 18.10).
    var structureTimeoutBuiltIn: Double = 90
    /// A structurer that takes longer has failed (spec 8.1).
    var structureTimeoutLocal: Double = 20
    var structureTimeoutCloud: Double = 15
    /// One turn of the "Sorting…" spinner (spec 6.7).
    var spinnerPeriod: Double = 0.8

    // MARK: Dictation (spec 7)

    /// The longest dictation, seconds; the timer turns red this long before the end.
    var dictationLimit: Double = 180
    var dictationWarning: Double = 15
    /// How often the timer and the level meter are refreshed.
    var dictationTick: Double = 0.05
    /// One beat of the microphone's pulse while it records.
    var dictationPulseDuration: Double = 0.6
    /// The speech model (about half a gigabyte in memory) is let go this long
    /// after the last dictation. Read once, at launch.
    var speechModelIdleUnload: Double = 120
    /// The built-in model leaves memory this long after its last answer (spec 18.10 A1).
    var structuringModelIdleUnload: Double = 300

    /// On (spec 4.10): ⌘Z brings a peeled sticker back while its toast is up. The
    /// key is taken from the app in front for those few seconds, or until the next click.
    var undoPeelUsesCommandZ = true

    // MARK: Animation (6.7)

    /// 1 = normal speed, 3 and 10 slow everything down for inspection.
    var animationSlowdown: Double = 1

    func scaled(_ duration: Double) -> Double {
        // Zero switches animations off (`--ui-testing`, spec 17.4).
        duration * max(animationSlowdown, 0)
    }
}

/// Cubic Bézier curves from the animation tokens table (spec 6.7).
struct MotionCurve: Sendable {
    let c1x: Float
    let c1y: Float
    let c2x: Float
    let c2y: Float

    /// How far along the animation is when `progress` of its time has passed,
    /// for animations driven frame by frame.
    func value(at progress: Double) -> Double {
        CubicBezier(Double(c1x), Double(c1y), Double(c2x), Double(c2y)).value(at: progress)
    }

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

    /// The same curve played backwards in time: what came out with it goes back with this.
    var reversed: MotionCurve {
        MotionCurve(c1x: 1 - c2x, c1y: 1 - c2y, c2x: 1 - c1x, c2y: 1 - c1y)
    }
}
