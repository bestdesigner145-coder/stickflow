// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AVFoundation
import Foundation
import StickflowCore

/// Records the default microphone (spec 7). Nothing is written to disk: the
/// sound lives in memory until it is recognised.
@MainActor
final class MicrophoneRecorder: VoiceRecorder {
    private let engine = AVAudioEngine()
    private let tap = AudioTap()

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError.unavailable }
        tap.reset(sampleRate: format.sampleRate)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: tap.makeBlock())
        engine.prepare()
        try engine.start()
    }

    func stop() -> AudioBuffer16k {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let recorded = tap.take()
        return AudioBuffer16k(samples: AudioResampler.resample(recorded.samples, from: recorded.sampleRate))
    }

    var level: Float { tap.level }
}

/// Collects what the audio thread hands over. It belongs to no actor: the tap
/// block is called on a real-time thread, so everything here is behind a lock.
final class AudioTap: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate = 48000.0
    private var currentLevel: Float = 0

    func reset(sampleRate: Double) {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        self.sampleRate = sampleRate
        currentLevel = 0
        lock.unlock()
    }

    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return currentLevel
    }

    func take() -> (samples: [Float], sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        let result = (samples, sampleRate)
        samples = []
        currentLevel = 0
        return result
    }

    /// The block for `installTap`. It is made here, outside the main actor,
    /// because the audio thread calls it.
    func makeBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in
            self.append(buffer)
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var chunk = [Float](repeating: 0, count: count)
        if let channels = buffer.floatChannelData {
            // Several channels are mixed down to one.
            let channelCount = max(Int(buffer.format.channelCount), 1)
            for channel in 0..<channelCount {
                let data = channels[channel]
                for index in 0..<count {
                    chunk[index] += data[index] / Float(channelCount)
                }
            }
        } else if let channels = buffer.int16ChannelData {
            let data = channels[0]
            for index in 0..<count {
                chunk[index] = Float(data[index]) / 32768
            }
        } else {
            return
        }
        let loudness = AudioLevel.rms(chunk)
        lock.lock()
        samples.append(contentsOf: chunk)
        currentLevel = loudness
        lock.unlock()
    }
}
