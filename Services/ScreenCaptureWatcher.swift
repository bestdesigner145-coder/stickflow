// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// Tells whether something is recording or sharing the screen right now.
///
/// EXPERIMENTAL. macOS has no public API for this question (iOS has
/// `UIScreen.isCaptured`). The window server does know the answer and exposes it
/// through the private function `CGSIsScreenWatcherPresent`. The symbol is looked
/// up at run time: if a future macOS drops it, `isAvailable` turns false and the
/// feature quietly switches itself off instead of crashing. It is a private
/// interface, so it may also change meaning; nothing in the UI may promise that
/// stickers are hidden from a capture.
@MainActor
final class ScreenCaptureWatcher: NSObject {
    private typealias Probe = @convention(c) () -> Bool

    /// Called on the main actor when capture starts or stops.
    var onChange: ((Bool) -> Void)?

    private let probe: Probe?
    private var timer: Timer?
    private(set) var isCaptured = false

    override init() {
        // RTLD_DEFAULT: search every image already loaded into the process.
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        if let symbol = dlsym(handle, "CGSIsScreenWatcherPresent") {
            probe = unsafeBitCast(symbol, to: Probe.self)
        } else {
            probe = nil
        }
        super.init()
    }

    /// False when this macOS does not have the function.
    var isAvailable: Bool { probe != nil }

    /// Asks the window server right now. `nil` when the function is missing.
    func readNow() -> Bool? {
        probe.map { $0() }
    }

    /// Starts polling. Cheap: one function call per second.
    func start() {
        guard timer == nil, isAvailable else { return }
        let newTimer = Timer(timeInterval: 1.0, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        newTimer.tolerance = 0.3
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isCaptured {
            isCaptured = false
            onChange?(false)
        }
    }

    @objc private func poll() {
        guard let captured = readNow(), captured != isCaptured else { return }
        isCaptured = captured
        onChange?(captured)
    }
}
