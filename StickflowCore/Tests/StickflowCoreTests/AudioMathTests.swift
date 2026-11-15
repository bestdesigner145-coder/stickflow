// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

@testable import StickflowCore
import XCTest

final class AudioMathTests: XCTestCase {
    func testDownsamplingAveragesWhatItCovers() {
        XCTAssertEqual(AudioResampler.resample([0, 3, 6, 9, 12, 15], from: 48000), [3, 12])
        let steady = [Float](repeating: 0.25, count: 4410)
        let resampled = AudioResampler.resample(steady, from: 44100)
        XCTAssertEqual(resampled.count, 1600)
        for sample in resampled {
            XCTAssertEqual(sample, 0.25, accuracy: 0.0001)
        }
    }

    func testResamplingKeepsALowTone() {
        // 200 Hz at 48 kHz must still be 200 Hz at 16 kHz.
        let source = (0..<4800).map { Float(sin(2 * Double.pi * 200 * Double($0) / 48000)) }
        let result = AudioResampler.resample(source, from: 48000)
        XCTAssertEqual(result.count, 1600)
        for index in stride(from: 0, to: 1600, by: 37) {
            // The mean of three samples sits at the middle one.
            let expected = sin(2 * Double.pi * 200 * (Double(index) + 1.0 / 3) / 16000)
            XCTAssertEqual(Double(result[index]), expected, accuracy: 0.01)
        }
    }

    func testUpsamplingAndEdges() {
        XCTAssertEqual(AudioResampler.resample([0, 1, 2], from: 8000), [0, 0.5, 1, 1.5, 2, 2])
        XCTAssertEqual(AudioResampler.resample([1, 2, 3], from: 16000), [1, 2, 3])
        XCTAssertEqual(AudioResampler.resample([], from: 48000), [])
        XCTAssertEqual(AudioResampler.resample([1], from: 48000), [])
        XCTAssertEqual(AudioResampler.resample([1, 2], from: 0), [])
    }

    func testLevels() {
        XCTAssertEqual(AudioLevel.rms([]), 0)
        XCTAssertEqual(AudioLevel.rms([0.5, -0.5, 0.5, -0.5]), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AudioLevel.rms([4, -4]), 1)
        XCTAssertEqual(AudioLevel.meter(0.05), 0.3, accuracy: 0.0001)
        XCTAssertEqual(AudioLevel.meter(0.5), 1)
        XCTAssertEqual(AudioLevel.meter(-1), 0)
    }

    func testDictationClock() {
        XCTAssertEqual(DictationClock.label(elapsed: 0), "0:00")
        XCTAssertEqual(DictationClock.label(elapsed: 7.9), "0:07")
        XCTAssertEqual(DictationClock.label(elapsed: 165), "2:45")
        XCTAssertEqual(DictationClock.label(elapsed: -3), "0:00")
        XCTAssertFalse(DictationClock.isEnding(elapsed: 164, limit: 180, warning: 15))
        XCTAssertTrue(DictationClock.isEnding(elapsed: 165, limit: 180, warning: 15))
        XCTAssertFalse(DictationClock.isOver(elapsed: 179.9, limit: 180))
        XCTAssertTrue(DictationClock.isOver(elapsed: 180, limit: 180))
    }
}
