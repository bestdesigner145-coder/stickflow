// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

@testable import StickflowCore
import XCTest

final class SpeechModelTests: XCTestCase {
    private func tone(_ hertz: Double, amplitude: Double = 0.5, count: Int) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * Double.pi * hertz * Double($0) / 16000)) }
    }

    // MARK: Mel front end

    func testFrameCounts() {
        XCTAssertEqual(MelFrontend.frameCount(sampleCount: 319), 0)
        XCTAssertEqual(MelFrontend.frameCount(sampleCount: 320), 1)
        XCTAssertEqual(MelFrontend.frameCount(sampleCount: 800), 4)
        XCTAssertEqual(MelFrontend.frameCount(sampleCount: 30 * 16000), 2999, "the model's 30 s window")
    }

    func testMelFiltersAreTorchaudiosHTKTriangles() {
        let frontend = MelFrontend()
        XCTAssertEqual(frontend.filters.count, 64)
        XCTAssertEqual(frontend.filters[0].first, 1)
        XCTAssertEqual(frontend.filters[0].weights.count, 1)
        XCTAssertEqual(frontend.filters[0].weights[0], 0.22376345, accuracy: 0.00001)
        XCTAssertEqual(frontend.filters.map(\.weights.count).max(), 13)
        for filter in frontend.filters {
            XCTAssertFalse(filter.weights.isEmpty)
            XCTAssertLessThanOrEqual(filter.first + filter.weights.count, 161)
            XCTAssertTrue(filter.weights.allSatisfy { $0 > 0 && $0 <= 1 })
        }
        XCTAssertEqual(MelFrontend.melToHertz(MelFrontend.hertzToMel(1234)), 1234, accuracy: 0.0001)
        XCTAssertEqual(frontend.window[0], 0)
        XCTAssertEqual(frontend.window[160], 1, accuracy: 0.000001)
        XCTAssertEqual(frontend.window[80], 0.5, accuracy: 0.000001)
    }

    func testATonePeaksInItsMelBand() {
        // 1 kHz falls exactly on bin 20: power 1600 there, 400 either side.
        let frontend = MelFrontend()
        let samples = tone(1000, count: 800)
        let power = frontend.powerSpectrumSlowly(samples, frame: 0)
        XCTAssertEqual(power[20], 1600, accuracy: 0.5)
        XCTAssertEqual(power[19], 400, accuracy: 0.2)
        XCTAssertEqual(power[21], 400, accuracy: 0.2)

        let frames = MelFrontend.frameCount(sampleCount: samples.count)
        let features = frontend.logMel(samples, frames: frames)
        XCTAssertEqual(features.count, 64 * 4)
        for frame in 0..<frames {
            XCTAssertEqual(features[21 * frames + frame], 6.2884, accuracy: 0.002)
            XCTAssertEqual(features[22 * frames + frame], 7.3838, accuracy: 0.002)
            XCTAssertEqual(features[23 * frames + frame], 5.5294, accuracy: 0.002)
            XCTAssertLessThan(features[10 * frames + frame], -5)
            XCTAssertLessThan(features[40 * frames + frame], -5)
        }
    }

    func testFastTransformAgreesWithTheSlowOne() {
        // A sound with many frequencies in it: every band must come out the same.
        let frontend = MelFrontend()
        var samples = [Float](repeating: 0, count: 1120)
        for (hertz, amplitude) in [(180.0, 0.3), (440.0, 0.2), (1250.0, 0.25), (3300.0, 0.15), (6100.0, 0.1)] {
            for (index, value) in tone(hertz, amplitude: amplitude, count: samples.count).enumerated() {
                samples[index] += value
            }
        }
        let frames = MelFrontend.frameCount(sampleCount: samples.count)
        XCTAssertEqual(frames, 6)
        let features = frontend.logMel(samples, frames: frames)
        for frame in 0..<frames {
            let power = frontend.powerSpectrumSlowly(samples, frame: frame)
            for (mel, filter) in frontend.filters.enumerated() {
                var energy: Float = 0
                for (offset, weight) in filter.weights.enumerated() {
                    energy += weight * power[filter.first + offset]
                }
                guard energy > 0.001 else { continue }
                XCTAssertEqual(features[mel * frames + frame], log(energy), accuracy: 0.01, "mel \(mel), frame \(frame)")
            }
        }
    }

    func testSilenceAndTheEndOfTheSound() {
        let frontend = MelFrontend()
        let silence = frontend.logMel([], frames: 3)
        XCTAssertEqual(silence.count, 64 * 3)
        for value in silence {
            XCTAssertEqual(value, -20.7233, accuracy: 0.0001)
        }
        // Frames past the end of the sound are silence, as in a zero-padded window.
        let short = frontend.logMel(tone(1000, count: 320), frames: 4)
        XCTAssertEqual(short[22 * 4], 7.3838, accuracy: 0.002)
        XCTAssertEqual(short[22 * 4 + 3], -20.7233, accuracy: 0.0001)
        XCTAssertTrue(frontend.logMel(tone(1000, count: 320), frames: 0).isEmpty)
    }

    // MARK: Decoding

    func testGreedyDecodingTakesTokensUntilABlank() {
        let decoder = TransducerGreedyDecoder(blank: 9)
        // Frame 0 says 3 then 4, frame 1 nothing, frame 2 says 5. The state counts taken tokens.
        let script: [[Int]] = [[3, 4, 9], [9], [5, 9]]
        var asked: [(Int, Int, Int)] = []
        let tokens = decoder.decode(frames: 3, start: 0) { frame, last, state in
            asked.append((frame, last, state))
            let emitted = asked.filter { $0.0 == frame }.count - 1
            return (script[frame][emitted], state + 1)
        }
        XCTAssertEqual(tokens, [3, 4, 5])
        XCTAssertEqual(asked.map(\.1), [9, 3, 4, 4, 4, 5], "the last token is fed back, a blank is not")
        XCTAssertEqual(asked.map(\.2), [0, 1, 2, 2, 2, 3], "the state moves only when a token is taken")
    }

    func testGreedyDecodingStopsAFrameThatNeverBlanks() {
        let decoder = TransducerGreedyDecoder(blank: 0, maxSymbolsPerFrame: 4)
        let tokens = decoder.decode(frames: 2, start: 0) { _, _, state in (7, state) }
        XCTAssertEqual(tokens.count, 8)
        let none = TransducerGreedyDecoder(blank: 0).decode(frames: 0, start: 0) { _, _, state in (7, state) }
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(TransducerGreedyDecoder.argmax([0.1, 2.5, -1, 2.5]), 1)
        XCTAssertEqual(TransducerGreedyDecoder.argmax([-3, -2, -1]), 2)
    }

    func testPiecesBecomeText() {
        let pieces = ["<unk>", ".", ",", "▁", "е", "▁Включи", "▁с", "вет"]
        XCTAssertEqual(PieceText.join([5, 6, 7, 1], pieces: pieces), "Включи свет.")
        XCTAssertEqual(PieceText.join([3, 4, 2, 99, -1], pieces: pieces), "е,")
        XCTAssertEqual(PieceText.join([], pieces: pieces), "")
    }

    // MARK: Long speech

    func testShortSpeechIsOneWindow() {
        let chunker = SpeechChunker(maxLength: 1000, searchLength: 400, stride: 100)
        XCTAssertEqual(chunker.split([Float](repeating: 0.5, count: 1000)), [0..<1000])
        XCTAssertEqual(chunker.split([Float](repeating: 0.5, count: 10)), [0..<10])
        XCTAssertTrue(chunker.split([]).isEmpty)
    }

    func testLongSpeechIsCutWhereItIsQuiet() {
        let chunker = SpeechChunker(maxLength: 1000, searchLength: 400, stride: 100)
        var samples = [Float](repeating: 0.5, count: 2300)
        for index in 700..<800 {
            samples[index] = 0
        }
        for index in 1550..<1650 {
            samples[index] = 0.01
        }
        let ranges = chunker.split(samples)
        XCTAssertEqual(ranges, [0..<750, 750..<1600, 1600..<2300])
        XCTAssertTrue(ranges.allSatisfy { $0.count <= 1000 })
        // Even noise is cut as late as the window allows.
        XCTAssertEqual(chunker.split([Float](repeating: 0.5, count: 1500)), [0..<950, 950..<1500])
    }
}
