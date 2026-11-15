// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AVFoundation
import Foundation
import Speech
import StickflowCore

/// Apple's recogniser, strictly on the device (spec 7). The sound never leaves
/// the Mac: if this Mac can recognise the language only through Apple's servers,
/// the engine refuses instead (spec 0.8).
final class AppleSpeechEngine: SpeechEngine {
    let id = "apple-on-device"
    private let locale: Locale

    init(locale: Locale) {
        self.locale = locale
    }

    var isReady: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && (SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false)
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else { throw SpeechError.recognitionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { throw SpeechError.unavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw SpeechError.noOnDeviceModel }
        progress(1)
    }

    func transcribe(_ audio: AudioBuffer16k) async throws -> String {
        guard !audio.samples.isEmpty else { throw SpeechError.nothingHeard }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { throw SpeechError.unavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw SpeechError.noOnDeviceModel }
        guard let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: AudioResampler.speechRate,
                  channels: 1,
                  interleaved: false
              ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw SpeechError.failed("audio buffer")
        }
        for (index, sample) in audio.samples.enumerated() {
            channel[index] = sample
        }
        buffer.frameLength = AVAudioFrameCount(audio.samples.count)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.append(buffer)
        request.endAudio()

        let once = Once()
        do {
            let text: String = try await withCheckedThrowingContinuation { continuation in
                _ = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        if once.claim() { continuation.resume(returning: result.bestTranscription.formattedString) }
                    } else if let error {
                        if once.claim() { continuation.resume(throwing: error) }
                    }
                }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechError.nothingHeard }
            return text
        } catch let error as SpeechError {
            throw error
        } catch {
            let failure = error as NSError
            // 1110: the recogniser heard no speech.
            if failure.domain == "kAFAssistantErrorDomain", failure.code == 1110 { throw SpeechError.nothingHeard }
            throw SpeechError.failed(failure.localizedDescription)
        }
    }
}

/// Lets a callback that may fire more than once answer only the first time.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isClaimed { return false }
        isClaimed = true
        return true
    }
}
