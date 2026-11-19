// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AVFoundation
import Foundation
import StickflowCore

/// Reads a sound file as recognition wants it: mono, 16 kHz.
enum AudioFileReader {
    static func read(_ url: URL) throws -> AudioBuffer16k {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SpeechError.failed("\(url.lastPathComponent) is empty")
        }
        try file.read(into: buffer)
        let count = Int(buffer.frameLength)
        guard let channels = buffer.floatChannelData, count > 0 else {
            throw SpeechError.failed("\(url.lastPathComponent) cannot be read as samples")
        }
        let channelCount = max(Int(format.channelCount), 1)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for index in 0..<count {
                mono[index] += data[index] / Float(channelCount)
            }
        }
        return AudioBuffer16k(samples: AudioResampler.resample(mono, from: format.sampleRate))
    }
}
