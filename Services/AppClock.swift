// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// The time, behind a protocol so that tests and `--ui-testing` can fix it
/// (spec 17.4 calls it `Clock`; Swift's standard library has a `Clock` of its own).
protocol AppClock: Sendable {
    /// Wall-clock time, for the dates stored with stickers.
    var now: Date { get }
    /// Monotonic seconds, for timing what the pointer does.
    var uptime: TimeInterval { get }
}

struct SystemClock: AppClock {
    var now: Date { Date() }
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Always the same date; only the monotonic time moves, because timers need it.
struct FixedClock: AppClock {
    let now: Date

    /// The date `--ui-testing` runs on: 12 November 2026, 09:00 UTC.
    static let uiTesting = FixedClock(now: Date(timeIntervalSince1970: 1_794_474_000))

    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
