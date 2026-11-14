// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// What the pointer and the modifier keys are doing right now.
struct PointerSample {
    /// Cursor position in screen coordinates.
    let location: CGPoint
    let modifiers: NSEvent.ModifierFlags
    let isMouseDown: Bool
    /// Monotonic time in seconds.
    let time: TimeInterval
}

/// Watches the cursor without any permission prompts (spec 5.3).
///
/// Mouse-move monitors only tell us that the cursor moved. While it is close to
/// a sticker, a 60 Hz timer samples its position and the modifier keys; that is
/// how holding ⌥ is noticed even when the mouse is still (spec 4.6). The timer
/// stops as soon as no sticker needs it, so nothing runs while the user works elsewhere.
@MainActor
final class PointerTracker: NSObject {
    var onSample: ((PointerSample) -> Void)?
    /// Asked on every mouse move and after every sample.
    var needsPolling: ((CGPoint) -> Bool)?
    var pollInterval: () -> TimeInterval = { 1.0 / 60.0 }

    private var monitors: [Any] = []
    private var timer: Timer?

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

        // Events that go to other apps. Mouse events need no Accessibility permission.
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pointerMoved()
            }
        }
        if let global { monitors.append(global) }

        // Events that go to our own windows.
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pointerMoved()
            }
            return event
        }
        if let local { monitors.append(local) }
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        stopTimer()
    }

    /// Re-evaluates polling right now, e.g. after a sticker appeared under a still cursor.
    func kick() {
        pointerMoved()
    }

    private func pointerMoved() {
        guard timer == nil, needsPolling?(NSEvent.mouseLocation) == true else { return }
        startTimer()
    }

    private func startTimer() {
        let newTimer = Timer(
            timeInterval: max(pollInterval(), 1.0 / 240.0),
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        newTimer.tolerance = 0.002
        // `.common` keeps the timer running during menu tracking and drags.
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        tick()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        let location = NSEvent.mouseLocation
        let sample = PointerSample(
            location: location,
            modifiers: NSEvent.modifierFlags,
            isMouseDown: NSEvent.pressedMouseButtons != 0,
            time: ProcessInfo.processInfo.systemUptime
        )
        onSample?(sample)
        if needsPolling?(location) != true {
            stopTimer()
        }
    }
}
