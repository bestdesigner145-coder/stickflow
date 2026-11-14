// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import QuartzCore

extension NSView {
    /// Scales the view about its centre (appearing and peeling, spec 6.7).
    /// Only what is on screen changes; layout and hit-testing stay as they are.
    /// - Parameter keepsFinalState: leave the sticker at `end` when the animation
    ///   is over, for a sticker that is on its way out.
    func animateScale(
        from start: CGFloat,
        to end: CGFloat,
        duration: TimeInterval,
        curve: MotionCurve,
        keepsFinalState: Bool = false
    ) {
        guard let layer, duration > 0 else { return }
        // A layer scales about its anchor point; shift so that the centre stays put.
        let centre = CGPoint(
            x: layer.bounds.width * (0.5 - layer.anchorPoint.x),
            y: layer.bounds.height * (0.5 - layer.anchorPoint.y)
        )
        func transform(_ scale: CGFloat) -> CATransform3D {
            var result = CATransform3DMakeTranslation(-centre.x, -centre.y, 0)
            result = CATransform3DConcat(result, CATransform3DMakeScale(scale, scale, 1))
            return CATransform3DConcat(result, CATransform3DMakeTranslation(centre.x, centre.y, 0))
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: transform(start))
        animation.toValue = NSValue(caTransform3D: transform(end))
        animation.duration = duration
        animation.timingFunction = curve.timingFunction
        if keepsFinalState {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        layer.add(animation, forKey: "stickerScale")
    }
}
