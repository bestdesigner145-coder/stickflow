// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import QuartzCore

extension NSView {
    /// Scales the view about its centre (appearing and peeling, spec 6.7).
    /// Only what is on screen changes; layout and hit-testing stay as they are.
    /// - Parameter rotation: degrees the view has turned by the end, counter-clockwise.
    /// - Parameter keepsFinalState: leave the sticker at `end` when the animation
    ///   is over, for a sticker that is on its way out.
    func animateScale(
        from start: CGFloat,
        to end: CGFloat,
        rotation: CGFloat = 0,
        duration: TimeInterval,
        curve: MotionCurve,
        keepsFinalState: Bool = false
    ) {
        guard let layer, duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: Self.centredTransform(scale: start, in: layer))
        animation.toValue = NSValue(caTransform3D: Self.centredTransform(scale: end, rotation: rotation, in: layer))
        animation.duration = duration
        animation.timingFunction = curve.timingFunction
        if keepsFinalState {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        layer.add(animation, forKey: "stickerScale")
    }

    /// Runs the view's scale through `scales`, e.g. the squash of an impact.
    func animateScale(through scales: [CGFloat], duration: TimeInterval, curve: MotionCurve) {
        guard let layer, duration > 0, scales.count >= 2 else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = scales.map { NSValue(caTransform3D: Self.centredTransform(scale: $0, in: layer)) }
        animation.duration = duration
        animation.timingFunction = curve.timingFunction
        layer.add(animation, forKey: "stickerScale")
    }

    /// Moves the view to `origin` and turns it about its centre to `rotation`
    /// degrees, as explicit Core Animation animations: they run on the render
    /// server at the display's rate, and nothing is laid out or drawn per frame.
    /// The turn is held by its animation, because AppKit owns the layer's own
    /// transform. With no duration the view is simply there.
    func slide(to origin: CGPoint, rotation: CGFloat, duration: TimeInterval, curve: MotionCurve) {
        guard let layer else {
            setFrameOrigin(origin)
            return
        }
        // Where the view is on screen right now, in the middle of a move or not.
        let shown = layer.presentation()
        let fromPosition = shown?.position ?? layer.position
        let fromTransform = shown?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrameOrigin(origin)
        CATransaction.commit()

        let turned = Self.centredTransform(scale: 1, rotation: rotation, in: layer)
        let turn = CABasicAnimation(keyPath: "transform")
        turn.fromValue = NSValue(caTransform3D: duration > 0 ? fromTransform : turned)
        turn.toValue = NSValue(caTransform3D: turned)
        turn.duration = max(duration, 0.001)
        turn.timingFunction = curve.timingFunction
        turn.fillMode = .forwards
        turn.isRemovedOnCompletion = rotation == 0
        layer.add(turn, forKey: "slideTurn")

        guard duration > 0 else {
            layer.removeAnimation(forKey: "slideMove")
            return
        }
        // Both ends given: AppKit may move the layer's model to the new frame only
        // in its next display pass, and a move "to the model" would then be no move (fix K1).
        let toPosition = CGPoint(
            x: origin.x + layer.anchorPoint.x * frame.width,
            y: origin.y + layer.anchorPoint.y * frame.height
        )
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: fromPosition)
        move.toValue = NSValue(point: toPosition)
        move.fillMode = .backwards
        move.duration = duration
        move.timingFunction = curve.timingFunction
        layer.add(move, forKey: "slideMove")
    }

    /// Changes the view's opacity as an explicit Core Animation animation.
    func fade(to alpha: CGFloat, duration: TimeInterval, curve: MotionCurve) {
        guard let layer, duration > 0 else {
            layer?.removeAnimation(forKey: "fade")
            alphaValue = alpha
            return
        }
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        alphaValue = alpha
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.duration = duration
        animation.timingFunction = curve.timingFunction
        layer.add(animation, forKey: "fade")
    }

    /// Drops whatever scale animation is running or was left at its end state.
    func removeScaleAnimation() {
        layer?.removeAnimation(forKey: "stickerScale")
    }

    /// A layer scales and turns about its anchor point; shift so that the centre stays put.
    private static func centredTransform(scale: CGFloat, rotation: CGFloat = 0, in layer: CALayer) -> CATransform3D {
        let centre = CGPoint(
            x: layer.bounds.width * (0.5 - layer.anchorPoint.x),
            y: layer.bounds.height * (0.5 - layer.anchorPoint.y)
        )
        var result = CATransform3DMakeTranslation(-centre.x, -centre.y, 0)
        result = CATransform3DConcat(result, CATransform3DMakeScale(scale, scale, 1))
        if rotation != 0 {
            result = CATransform3DConcat(result, CATransform3DMakeRotation(rotation * .pi / 180, 0, 0, 1))
        }
        return CATransform3DConcat(result, CATransform3DMakeTranslation(centre.x, centre.y, 0))
    }
}
