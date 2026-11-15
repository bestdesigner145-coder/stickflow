// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

/// Shows one sticker as a picture in the `EffectsOverlay` in place of its own
/// window: while it flies to its place, while its corner is pulled, while it
/// flies back to the pad. The window stays where it is, invisible, and takes over
/// again when the picture is done.
@MainActor
final class StickerStandIn {
    private let panel: NSPanel
    private let rootView: StickerRootView
    private let tuning: Tuning
    private let preferences: Preferences

    private var sprite: StickerSprite?
    private var overlay: EffectsOverlay?
    private var pendingHide: DispatchWorkItem?

    /// The window must stay invisible: the picture stands in for it.
    private(set) var hidesWindow = false

    init(panel: NSPanel, rootView: StickerRootView, tuning: Tuning, preferences: Preferences) {
        self.panel = panel
        self.rootView = rootView
        self.tuning = tuning
        self.preferences = preferences
    }

    /// A picture of the sticker is in the overlay.
    var isUp: Bool { sprite != nil }

    /// The fold as it is drawn now; `nil` while the sheet lies flat.
    var fold: PaperFold? { sprite?.fold }

    /// Puts a picture of the sticker, as it looks now, exactly over its paper.
    /// - Parameters:
    ///   - paperFrame: the paper on screen.
    ///   - screenFrame: the screen to cover; `nil` covers the surroundings of the sticker.
    /// - Returns: false when no picture could be made; the window then does the job itself.
    func show(in overlay: EffectsOverlay, paperFrame: CGRect, screenFrame: CGRect?, shadow: ShadowSpec) -> Bool {
        let screen = panel.screen ?? NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        guard let image = rootView.paperSnapshot(scale: scale) else { return false }
        let picture = StickerSprite(
            image: image,
            size: paperFrame.size,
            cornerRadius: rootView.metrics.cornerRadius,
            back: rootView.foldBackColor,
            scale: scale
        )
        picture.setShadow(shadow)
        dismiss(after: 0)
        sprite = picture
        self.overlay = overlay
        overlay.add(
            picture,
            paperFrame: paperFrame,
            screenFrame: screenFrame ?? panel.frame.insetBy(dx: -600, dy: -600),
            above: panel.level,
            hiddenFromCapture: preferences.hideFromScreenCapture
        )
        return true
    }

    /// Hides the window. Not at once by default: a moment after the picture is up,
    /// so that the two swap without a frame in which neither is there.
    func hideWindow(atOnce: Bool = false) {
        hidesWindow = true
        pendingHide?.cancel()
        pendingHide = nil
        guard !atOnce else {
            panel.alphaValue = 0
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hidesWindow else { return }
                self.panel.alphaValue = 0
            }
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + tuning.spriteHandoverDuration, execute: work)
    }

    /// The window takes over again; the caller gives it its opacity back. The
    /// picture dissolves over the window for `dissolve` seconds, then goes.
    func handBack(dissolve: TimeInterval) {
        pendingHide?.cancel()
        pendingHide = nil
        hidesWindow = false
        dismiss(after: dissolve)
    }

    func dismiss(after delay: TimeInterval) {
        guard let old = sprite else { return }
        sprite = nil
        overlay?.remove(old, after: delay)
    }

    func setCornerPull(_ pull: CGSize) {
        sprite?.setCornerPull(pull)
    }

    /// Flies the picture along an arc to where the paper is (spec 6.7: easeOut,
    /// a quick start and a soft landing), growing a little as it lifts off.
    /// - Parameters:
    ///   - start: centre of the paper at the start, screen coordinates.
    ///   - destination: centre of the paper in its place.
    ///   - completion: called when the picture has arrived, not when it was dismissed on the way.
    func fly(
        from start: CGPoint,
        to destination: CGPoint,
        lift: CGFloat,
        scale: CGFloat,
        duration: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let sprite, let overlay else { return }
        let path = CGMutablePath()
        path.move(to: overlay.point(fromScreen: start))
        path.addQuadCurve(
            to: overlay.point(fromScreen: destination),
            control: overlay.point(fromScreen: FlightPath.control(from: start, to: destination, lift: lift))
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak sprite] in
            MainActor.assumeIsolated {
                guard let self, let sprite, self.sprite === sprite else { return }
                completion()
            }
        }
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.duration = duration
        move.timingFunction = MotionCurve.easeOut.timingFunction
        sprite.layer.add(move, forKey: "flight")
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = scale
        grow.duration = min(duration, tuning.scaled(tuning.flightLiftOffDuration))
        grow.timingFunction = MotionCurve.easeOut.timingFunction
        sprite.layer.add(grow, forKey: "liftOff")
        sprite.layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    /// The picture leaves for good: it fades, and with a `target` it flies there,
    /// shrinking and turning.
    /// - Parameters:
    ///   - target: screen point to fly to; `nil` fades in place.
    ///   - turn: degrees, counterclockwise.
    func flyAway(
        to target: CGPoint?,
        endScale: Double,
        turn: Double,
        duration: TimeInterval,
        curve: MotionCurve,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let sprite, let overlay else {
            completion()
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        var animations: [CAAnimation] = [fade]
        if let target {
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = sprite.layer.position
            move.toValue = overlay.point(fromScreen: target)
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = endScale
            let rotate = CABasicAnimation(keyPath: "transform.rotation.z")
            rotate.fromValue = 0
            rotate.toValue = turn * .pi / 180
            animations.append(contentsOf: [move, shrink, rotate])
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.timingFunction = curve.timingFunction
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                completion()
            }
        }
        sprite.layer.add(group, forKey: "leave")
        CATransaction.commit()
    }

    /// The sticker's window is closing.
    func reset() {
        pendingHide?.cancel()
        pendingHide = nil
        hidesWindow = false
        dismiss(after: 0)
    }
}
