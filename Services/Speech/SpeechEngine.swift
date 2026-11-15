// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
import StickflowCore

/// Recorded speech as recognition wants it: mono, 16 kHz (spec 7).
struct AudioBuffer16k: Sendable, Equatable {
    var samples: [Float]

    var duration: TimeInterval { Double(samples.count) / AudioResampler.speechRate }
}

enum SpeechError: Error, Equatable {
    case microphoneDenied
    case recognitionDenied
    /// This Mac can recognise the language only by sending the sound to a
    /// server, and Stickflow does not send it (spec 0.8).
    case noOnDeviceModel
    case unavailable
    case nothingHeard
    case failed(String)
}

/// Turns speech into text (spec 7). GigaAM and Apple's recogniser both sit
/// behind this, and tests replace it.
protocol SpeechEngine: Sendable {
    var id: String { get }
    var isReady: Bool { get }
    /// Asks for what the engine needs: a permission, a model to download.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(_ audio: AudioBuffer16k) async throws -> String
}

/// The microphone, behind a protocol so that tests need none.
@MainActor
protocol VoiceRecorder: AnyObject {
    /// Asks for the microphone the first time; the system shows its dialog once.
    func requestAccess() async -> Bool
    func start() throws
    /// Stops and hands over everything recorded since `start`.
    func stop() -> AudioBuffer16k
    /// Loudness right now, 0…1.
    var level: Float { get }
}

// MARK: - Test doubles

/// A microphone that records one second of quiet hum.
@MainActor
final class ScriptedRecorder: VoiceRecorder {
    var allowsAccess = true
    private(set) var isRunning = false

    func requestAccess() async -> Bool { allowsAccess }

    func start() throws {
        isRunning = true
    }

    func stop() -> AudioBuffer16k {
        isRunning = false
        return AudioBuffer16k(samples: [Float](repeating: 0.1, count: Int(AudioResampler.speechRate)))
    }

    var level: Float { isRunning ? 0.4 : 0 }
}

/// An engine that always hears the same sentence.
struct ScriptedSpeechEngine: SpeechEngine {
    /// The dictation from spec 8.5.
    static let sample = "Короче, сначала надо доделать экран кошелька, там типа пустые состояния и ошибки, "
        + "потом созвон с разработкой в три, и если успею, условно, пост в телегу написать"

    let id = "scripted"
    let isReady = true
    var text = ScriptedSpeechEngine.sample

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(1)
    }

    func transcribe(_ audio: AudioBuffer16k) async throws -> String {
        guard !audio.samples.isEmpty else { throw SpeechError.nothingHeard }
        return text
    }
}
