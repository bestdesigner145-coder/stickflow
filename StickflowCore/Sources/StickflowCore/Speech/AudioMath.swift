// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// Brings recorded sound to the rate speech recognition expects (spec 7: 16 kHz mono).
public enum AudioResampler {
    public static let speechRate = 16000.0

    /// - Parameters:
    ///   - samples: mono samples at `source` Hz.
    ///   - target: the wanted rate.
    /// Going down, every output sample is the mean of the stretch of input it
    /// covers, which also keeps what is above the new rate from folding back.
    /// Going up, samples are joined by straight lines.
    public static func resample(_ samples: [Float], from source: Double, to target: Double = speechRate) -> [Float] {
        guard source > 0, target > 0, !samples.isEmpty else { return [] }
        if abs(source - target) < 0.5 { return samples }
        let ratio = source / target
        let count = Int((Double(samples.count) / ratio).rounded(.down))
        guard count > 0 else { return [] }
        var output = [Float](repeating: 0, count: count)
        if ratio > 1 {
            let length = Double(samples.count)
            for index in 0..<count {
                let start = Double(index) * ratio
                let end = min(start + ratio, length)
                var sum = 0.0
                var position = start
                while position < end - 1e-9 {
                    let cell = Int(position)
                    let next = min(Double(cell + 1), end)
                    sum += Double(samples[cell]) * (next - position)
                    position = next
                }
                output[index] = Float(sum / (end - start))
            }
        } else {
            for index in 0..<count {
                let position = Double(index) * ratio
                let cell = Int(position)
                let fraction = Float(position - Double(cell))
                let next = min(cell + 1, samples.count - 1)
                output[index] = samples[cell] * (1 - fraction) + samples[next] * fraction
            }
        }
        return output
    }
}

public enum AudioLevel {
    /// Loudness of a stretch of sound, 0…1: the root mean square of its samples.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return Float(min((sum / Double(samples.count)).squareRoot(), 1))
    }

    /// What the meter shows for a loudness: quiet speech must already move it.
    public static func meter(_ rms: Float) -> Float {
        min(max(rms, 0) * 6, 1)
    }
}

/// The dictation timer (spec 7: three minutes at most, the timer turns red
/// fifteen seconds before the end).
public enum DictationClock {
    /// "0:07", "2:45".
    public static func label(elapsed: TimeInterval) -> String {
        let seconds = max(Int(elapsed.rounded(.down)), 0)
        let rest = seconds % 60
        return "\(seconds / 60):\(rest < 10 ? "0" : "")\(rest)"
    }

    public static func isEnding(elapsed: TimeInterval, limit: TimeInterval, warning: TimeInterval) -> Bool {
        elapsed >= limit - warning
    }

    public static func isOver(elapsed: TimeInterval, limit: TimeInterval) -> Bool {
        elapsed >= limit
    }
}
