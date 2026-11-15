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
