// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// Tells whether something is recording or sharing the screen right now (spec 5.2, layer L1).
///
/// macOS has no public API for this question (iOS has `UIScreen.isCaptured`). The
/// window server knows the answer and exposes it through a private function,
/// `SLSIsScreenWatcherPresent` (older name: `CGSIsScreenWatcherPresent`). The
/// symbol is looked up at run time: if a future macOS drops it, `isAvailable`
/// turns false and this layer switches itself off instead of crashing. Being
/// private, it may also change meaning, so the UI must not promise more than
/// "hides when you share the screen", and only for apps checked by hand.
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
        let symbol = dlsym(handle, "SLSIsScreenWatcherPresent") ?? dlsym(handle, "CGSIsScreenWatcherPresent")
        probe = symbol.map { unsafeBitCast($0, to: Probe.self) }
        super.init()
    }

    /// False when this macOS does not have the function.
    var isAvailable: Bool { probe != nil }

    /// Asks the window server right now. `nil` when the function is missing.
    func readNow() -> Bool? {
        probe.map { $0() }
    }

    /// Starts polling. Cheap: one function call per tick.
    /// - Parameter interval: seconds between checks; the spec asks for 0.1, so that
    ///   stickers are gone before the first shared frame.
    func start(interval: TimeInterval) {
        guard timer == nil, isAvailable else { return }
        let newTimer = Timer(timeInterval: interval, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        newTimer.tolerance = interval / 5
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
