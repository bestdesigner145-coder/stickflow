// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

/// What the draft shows of a dictation.
struct DictationStatus: Equatable {
    var state = Dictation.State.idle
    var elapsed: TimeInterval = 0
    var level: Float = 0
    var message: String?
    /// Something going on in the background, e.g. the speech model being downloaded.
    var notice: String?
    /// The limit is near: the timer is red.
    var isEnding = false
}

/// Dictation into the draft (spec 7, 4.3): the microphone is pressed, speech is
/// recorded until it is pressed again, then recognised and handed over as text.
/// Permissions are asked for at the first press, never earlier.
@MainActor
final class Dictation {
    enum State: Equatable {
        case idle
        /// Waiting for a permission or for the engine to get ready.
        case preparing
        case recording
        case recognizing
    }

    private(set) var state = State.idle
    /// Seconds recorded so far.
    private(set) var elapsed: TimeInterval = 0
    /// Loudness for the meter, 0…1.
    private(set) var level: Float = 0
    /// What went wrong last time; cleared by the next start.
    private(set) var message: String?
    /// How much of the speech model has been downloaded, 0…1; `nil` when no
    /// download is going on.
    private(set) var modelProgress: Double?

    /// State, time, level or message changed.
    var onChange: (() -> Void)?
    /// Speech was recognised.
    var onText: ((String) -> Void)?

    private let recorder: any VoiceRecorder
    private let engine: any SpeechEngine
    private let tuning: Tuning
    private var task: Task<Void, Never>?
    private var ticker: Timer?
    private var startedAt: TimeInterval = 0

    init(recorder: any VoiceRecorder, engine: any SpeechEngine, tuning: Tuning) {
        self.recorder = recorder
        self.engine = engine
        self.tuning = tuning
    }

    var isBusy: Bool { state != .idle }

    /// The microphone button, or Space while recording.
    func toggle() {
        switch state {
        case .idle: start()
        case .recording: stop()
        case .preparing, .recognizing: break
        }
    }

    /// The draft is closing: whatever was going on is dropped.
    func cancel() {
        task?.cancel()
        task = nil
        ticker?.invalidate()
        ticker = nil
        if state == .recording {
            _ = recorder.stop()
        }
        message = nil
        elapsed = 0
        level = 0
        set(.idle)
    }

    private func start() {
        message = nil
        elapsed = 0
        level = 0
        set(.preparing)
        let recorder = self.recorder
        let engine = self.engine
        task = Task { [weak self] in
            let hasMicrophone = await recorder.requestAccess()
            guard let self, !Task.isCancelled, self.state == .preparing else { return }
            guard hasMicrophone else {
                self.fail(with: SpeechError.microphoneDenied)
                return
            }
            do {
                // The engine may go on downloading its model after it is ready to listen.
                try await engine.prepare(progress: { [weak self] value in
                    Task { @MainActor [weak self] in
                        self?.modelDidProgress(value)
                    }
                })
            } catch {
                if !Task.isCancelled { self.fail(with: error) }
                return
            }
            guard !Task.isCancelled, self.state == .preparing else { return }
            do {
                try recorder.start()
            } catch {
                self.fail(with: error)
                return
            }
            self.startedAt = ProcessInfo.processInfo.systemUptime
            self.set(.recording)
            self.startTicking()
        }
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        level = 0
        let audio = recorder.stop()
        set(.recognizing)
        let engine = self.engine
        task = Task { [weak self] in
            do {
                let text = try await engine.transcribe(audio)
                guard let self, !Task.isCancelled, self.state == .recognizing else { return }
                self.set(.idle)
                self.onText?(text)
            } catch {
                guard let self, !Task.isCancelled, self.state == .recognizing else { return }
                self.fail(with: error)
            }
        }
    }

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: tuning.dictationTick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    private func tick() {
        guard state == .recording else { return }
        elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        level = AudioLevel.meter(recorder.level)
        if DictationClock.isOver(elapsed: elapsed, limit: tuning.dictationLimit) {
            // Spec 7: three minutes at most.
            stop()
        } else {
            onChange?()
        }
    }

    private func modelDidProgress(_ value: Double) {
        let shown = value < 1 ? value : nil
        // A hundred steps are enough for the eye.
        guard shown.map({ Int($0 * 100) }) != modelProgress.map({ Int($0 * 100) }) else { return }
        modelProgress = shown
        onChange?()
    }

    private func fail(with error: any Error) {
        message = Self.message(for: error)
        level = 0
        set(.idle)
    }

    private func set(_ new: State) {
        state = new
        onChange?()
    }

    /// What to tell the user, and what they can do about it.
    static func message(for error: any Error) -> String {
        switch error as? SpeechError {
        case .microphoneDenied: L10n.dictationNoMicrophone
        case .recognitionDenied: L10n.dictationNoRecognition
        case .noOnDeviceModel: L10n.dictationNoOnDeviceModel
        case .nothingHeard: L10n.dictationNothingHeard
        case .unavailable, .failed, nil: L10n.dictationFailed
        }
    }
}
