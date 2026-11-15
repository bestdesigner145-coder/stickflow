// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

/// One transparent window over the whole screen in which stickers move as
/// Core Animation layers: the flight to their place, the corner being peeled,
/// the way back to the pad (spec 6.7).
///
/// A sticker's own window is a tight box around the paper. Moving that window
/// frame by frame stutters, and anything drawn in it is cut at its edges. Here a
/// picture of the sticker moves on the GPU and nothing cuts it. The window never
/// takes a click and is on screen only while something is in it.
@MainActor
final class EffectsOverlay {
    private let panel: NSPanel
    private let host = CALayer()
    private var removals: [ObjectIdentifier: DispatchWorkItem] = [:]

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = NSView(frame: .zero)
        view.layer = host
        view.wantsLayer = true
        panel.contentView = view
    }

    var isVisible: Bool { panel.isVisible }

    /// Number of stickers drawn in the overlay right now.
    var spriteCount: Int { host.sublayers?.count ?? 0 }

    /// Puts `sprite` on screen so that its paper covers `paperFrame` (screen coordinates).
    /// - Parameters:
    ///   - screenFrame: the screen the overlay covers.
    ///   - level: the level of the sticker's own window; the overlay goes above it.
    ///   - hiddenFromCapture: follows the sticker windows (spec 5.2, L3).
    func add(_ sprite: StickerSprite, paperFrame: CGRect, screenFrame: CGRect, above level: NSWindow.Level, hiddenFromCapture: Bool) {
        if panel.frame != screenFrame {
            panel.setFrame(screenFrame, display: false)
        }
        panel.level = NSWindow.Level(rawValue: max(level.rawValue, NSWindow.Level.floating.rawValue) + 2)
        let sharing: NSWindow.SharingType = hiddenFromCapture ? .none : .readOnly
        if panel.sharingType != sharing {
            panel.sharingType = sharing
        }
        removals.removeValue(forKey: ObjectIdentifier(sprite))?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.layer.position = point(fromScreen: CGPoint(x: paperFrame.midX, y: paperFrame.midY))
        if sprite.layer.superlayer !== host {
            host.addSublayer(sprite.layer)
        }
        CATransaction.commit()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        // On screen now, not at the end of the event: the sticker's own window is about to hide.
        CATransaction.flush()
    }

    func point(fromScreen point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
    }

    /// Takes the sprite away. With `after`, it dissolves over that time first, so that
    /// the sticker's own window, which has just come back underneath, is never missing.
    func remove(_ sprite: StickerSprite, after delay: TimeInterval = 0) {
        let key = ObjectIdentifier(sprite)
        removals.removeValue(forKey: key)?.cancel()
        guard delay > 0 else {
            finishRemoving(sprite)
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = sprite.layer.presentation()?.opacity ?? sprite.layer.opacity
        fade.toValue = 0
        fade.duration = delay
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        sprite.layer.add(fade, forKey: "dissolve")
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.finishRemoving(sprite)
            }
        }
        removals[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func finishRemoving(_ sprite: StickerSprite) {
        removals.removeValue(forKey: ObjectIdentifier(sprite))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.layer.removeAllAnimations()
        sprite.layer.removeFromSuperlayer()
        CATransaction.commit()
        if host.sublayers?.isEmpty ?? true {
            panel.orderOut(nil)
        }
    }
}

/// A sticker as a picture: the paper with its text, its shadow, and the corner
/// folded over if it is being pulled. Lives in the `EffectsOverlay`.
///
/// Coordinates are those of Core Animation: the origin is the paper's bottom left
/// corner and y grows upwards.
@MainActor
final class StickerSprite {
    /// Carries the position, the scale and the rotation of the whole sticker.
    let layer = CALayer()
    private let shadowLayer = CALayer()
    private let paperLayer = CALayer()
    private let paperMask = CAShapeLayer()
    private let flapLayer = CAShapeLayer()
    private let size: CGSize
    private let cornerRadius: CGFloat
    private(set) var fold: PaperFold?

    /// - Parameters:
    ///   - image: the flat paper with everything on it, no shadow.
    ///   - back: colour of the back of the sheet.
    init(image: CGImage, size: CGSize, cornerRadius: CGFloat, back: NSColor, scale: CGFloat) {
        self.size = size
        self.cornerRadius = cornerRadius
        let bounds = CGRect(origin: .zero, size: size)
        layer.bounds = bounds
        for sublayer in [shadowLayer, paperLayer, flapLayer] {
            sublayer.frame = bounds
            layer.addSublayer(sublayer)
        }
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0

        paperLayer.contents = image
        paperLayer.contentsScale = scale
        paperLayer.contentsGravity = .resize
        paperMask.frame = bounds

        flapLayer.fillColor = back.cgColor
        flapLayer.strokeColor = NSColor.black.withAlphaComponent(0.10).cgColor
        flapLayer.lineWidth = 0.5
        flapLayer.shadowColor = NSColor.black.cgColor
        flapLayer.shadowOpacity = 0.28
        flapLayer.shadowRadius = 3
        flapLayer.shadowOffset = CGSize(width: -1, height: -1)
        flapLayer.isHidden = true
        setFold(nil)
    }

    func setShadow(_ spec: ShadowSpec) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.shadowOpacity = Float(spec.opacity)
        shadowLayer.shadowRadius = spec.blur / 2
        shadowLayer.shadowOffset = CGSize(width: 0, height: -spec.offsetY)
        CATransaction.commit()
    }

    /// Folds the bottom right corner as if it had been pulled by `pull` (left and
    /// up are negative, as in the sticker's view). Returns false when the pull
    /// would turn the whole sheet over; the last fold then stays.
    @discardableResult
    func setCornerPull(_ pull: CGSize) -> Bool {
        guard hypot(pull.width, pull.height) > 0.5 else {
            setFold(nil)
            return true
        }
        // The fold is worked out with y growing downwards, like the view.
        let paper = CGRect(origin: .zero, size: size)
        let corner = CGPoint(x: paper.maxX, y: paper.maxY)
        let target = CGPoint(x: corner.x + pull.width, y: corner.y + pull.height)
        guard let fold = PaperFold.make(paper: paper, corner: corner, pulledTo: target) else { return false }
        setFold(fold)
        return true
    }

    private func setFold(_ fold: PaperFold?) {
        self.fold = fold
        let height = size.height
        func path(_ polygon: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: polygon.map { CGPoint(x: $0.x, y: height - $0.y) })
            path.closeSubpath()
            return path
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let fold {
            // Paper, and its shadow, only where the sheet still lies flat.
            let kept = path(fold.kept)
            paperMask.path = kept
            paperLayer.mask = paperMask
            shadowLayer.shadowPath = kept
            let flap = path(fold.flap)
            flapLayer.path = flap
            flapLayer.shadowPath = flap
            flapLayer.isHidden = false
        } else {
            paperLayer.mask = nil
            shadowLayer.shadowPath = CGPath(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
            flapLayer.isHidden = true
        }
        CATransaction.commit()
    }
}
