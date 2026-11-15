// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// Drives an animation frame by frame, for motion that Core Animation cannot
/// describe by itself: a window flying along an arc, a corner springing back.
/// Any such animation can be finished at once (spec 6.7: every animation is interruptible).
@MainActor
final class FrameAnimator: NSObject {
    private var timer: Timer?
    private var startedAt: TimeInterval = 0
    private var duration: TimeInterval = 0
    private var step: ((TimeInterval) -> Void)?
    private var completion: (() -> Void)?

    var isRunning: Bool { timer != nil }

    /// - Parameters:
    ///   - step: called every frame with the seconds elapsed, and once more with `duration` at the end.
    ///   - completion: called after the last step, also when the animation is finished early.
    func run(duration: TimeInterval, step: @escaping (TimeInterval) -> Void, completion: @escaping () -> Void) {
        cancel()
        guard duration > 0 else {
            step(duration)
            completion()
            return
        }
        self.duration = duration
        self.step = step
        self.completion = completion
        startedAt = ProcessInfo.processInfo.systemUptime
        let newTimer = Timer(timeInterval: 1.0 / 120, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        step(0)
    }

    /// Jumps to the end state.
    func finish() {
        guard timer != nil else { return }
        let lastStep = step
        let done = completion
        let total = duration
        cancel()
        lastStep?(total)
        done?()
    }

    /// Stops where it is, without the end state and without `completion`.
    func cancel() {
        timer?.invalidate()
        timer = nil
        step = nil
        completion = nil
    }

    @objc private func tick() {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        if elapsed >= duration {
            finish()
        } else {
            step?(elapsed)
        }
    }
}
