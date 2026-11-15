// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Accelerate
import Foundation

/// The log-mel front end of GigaAM-v3 (spec 7), exactly as the model was
/// trained: 16 kHz, a 320-sample periodic Hann window every 160 samples, no
/// centring, the power spectrum through 64 triangular HTK mel filters without
/// normalisation, then `log(clamp(x, 1e-9, 1e9))`. These are the defaults of
/// torchaudio's `MelSpectrogram` with the values from the model's config.
public struct MelFrontend: Sendable {
    public static let sampleRate = 16000.0
    public static let fftSize = 320
    public static let hop = 160
    public static let melCount = 64
    static let binCount = fftSize / 2 + 1

    /// One mel filter: its weights for the bins from `first` on.
    struct Filter: Sendable {
        var first: Int
        var weights: [Float]
    }

    let window: [Float]
    let filters: [Filter]

    public init() {
        let size = Self.fftSize
        window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
        filters = Self.makeFilters()
    }

    /// How many frames `sampleCount` samples give.
    public static func frameCount(sampleCount: Int) -> Int {
        sampleCount < fftSize ? 0 : (sampleCount - fftSize) / hop + 1
    }

    static func hertzToMel(_ hertz: Double) -> Double {
        2595 * log10(1 + hertz / 700)
    }

    static func melToHertz(_ mel: Double) -> Double {
        700 * (pow(10, mel / 2595) - 1)
    }

    static func makeFilters() -> [Filter] {
        let top = sampleRate / 2
        let bins = (0..<binCount).map { top * Double($0) / Double(binCount - 1) }
        let lowest = hertzToMel(0)
        let highest = hertzToMel(top)
        let points = (0..<(melCount + 2)).map { melToHertz(lowest + (highest - lowest) * Double($0) / Double(melCount + 1)) }
        return (0..<melCount).map { mel in
            let rise = points[mel + 1] - points[mel]
            let fall = points[mel + 2] - points[mel + 1]
            var first = 0
            var weights: [Float] = []
            for (bin, hertz) in bins.enumerated() {
                let value = max(0, min((hertz - points[mel]) / rise, (points[mel + 2] - hertz) / fall))
                if value > 0 {
                    if weights.isEmpty { first = bin }
                    weights.append(Float(value))
                } else if !weights.isEmpty {
                    break
                }
            }
            return Filter(first: first, weights: weights)
        }
    }

    /// Log-mel features, one row per mel band: `result[mel * frames + frame]`.
    /// - Parameters:
    ///   - samples: mono sound at 16 kHz.
    ///   - frames: how many frames to make; where the sound has ended it counts as silence.
    public func logMel(_ samples: [Float], frames: Int) -> [Float] {
        let size = Self.fftSize
        let bins = Self.binCount
        var result = [Float](repeating: 0, count: Self.melCount * frames)
        let transform = vDSP.DFT(count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        guard frames > 0, let transform else { return result }
        var real = [Float](repeating: 0, count: size)
        let zeros = [Float](repeating: 0, count: size)
        var outReal = [Float](repeating: 0, count: size)
        var outImaginary = [Float](repeating: 0, count: size)
        var power = [Float](repeating: 0, count: bins)
        for frame in 0..<frames {
            let start = frame * Self.hop
            for index in 0..<size {
                let position = start + index
                real[index] = position < samples.count ? samples[position] * window[index] : 0
            }
            transform.transform(inputReal: real, inputImaginary: zeros, outputReal: &outReal, outputImaginary: &outImaginary)
            for bin in 0..<bins {
                power[bin] = outReal[bin] * outReal[bin] + outImaginary[bin] * outImaginary[bin]
            }
            for (mel, filter) in filters.enumerated() {
                var energy: Float = 0
                for (offset, weight) in filter.weights.enumerated() {
                    energy += weight * power[filter.first + offset]
                }
                result[mel * frames + frame] = Foundation.log(min(max(energy, 1e-9), 1e9))
            }
        }
        return result
    }

    /// The power spectrum of one windowed frame, worked out the slow way. The
    /// tests hold the fast transform against it.
    func powerSpectrumSlowly(_ samples: [Float], frame: Int) -> [Float] {
        let size = Self.fftSize
        let start = frame * Self.hop
        return (0..<Self.binCount).map { bin in
            var real = 0.0
            var imaginary = 0.0
            for index in 0..<size where start + index < samples.count {
                let value = Double(samples[start + index] * window[index])
                let angle = -2 * Double.pi * Double(bin) * Double(index) / Double(size)
                real += value * cos(angle)
                imaginary += value * sin(angle)
            }
            return Float(real * real + imaginary * imaginary)
        }
    }
}
