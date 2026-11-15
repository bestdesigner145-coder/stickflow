// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import CoreML
import Foundation
import StickflowCore

/// GigaAM-v3 `e2e_rnnt` through Core ML (spec 7): Russian speech into
/// punctuated text, on this Mac. The model is not in the app; `prepare`
/// downloads it once, by the user's action, and checks it.
///
/// The Core ML packages need macOS 15; on macOS 14 the engine is never ready
/// and the app stays with Apple's recogniser.
final class GigaAMEngine: SpeechEngine {
    let id = "gigaam-v3-e2e-rnnt"
    let store: SpeechModelStore
    private let runner: GigaAMRunner

    /// - Parameter idleUnload: seconds after the last use at which the models
    ///   leave memory (about half a gigabyte); the next dictation loads them again.
    init(store: SpeechModelStore, computeUnits: MLComputeUnits = .cpuAndGPU, idleUnload: TimeInterval = 120) {
        self.store = store
        runner = GigaAMRunner(computeUnits: computeUnits, idleUnload: idleUnload)
    }

    var isSupported: Bool {
        if #available(macOS 15, *) {
            return true
        }
        return false
    }

    /// The model is on this Mac. Loading it into memory happens at the first use.
    var isReady: Bool { isSupported && store.isInstalled }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard isSupported else { throw SpeechError.unavailable }
        if !store.isInstalled {
            try await store.install(progress: progress)
        }
        progress(1)
        try await runner.loadIfNeeded(from: store)
    }

    func transcribe(_ audio: AudioBuffer16k) async throws -> String {
        guard !audio.samples.isEmpty else { throw SpeechError.nothingHeard }
        guard isReady else { throw SpeechError.unavailable }
        try await runner.loadIfNeeded(from: store)
        let text = try await runner.transcribe(audio.samples)
        guard !text.isEmpty else { throw SpeechError.nothingHeard }
        return text
    }

    /// Loads the models ahead of the first transcription, e.g. while the user is
    /// still speaking. Does nothing if the model is not on this Mac.
    func warmUp() async {
        guard isReady else { return }
        try? await runner.loadIfNeeded(from: store)
    }

    var isLoaded: Bool {
        get async { await runner.isLoaded }
    }

    /// Where the time of the last transcription went, for the probe.
    func lastTimings() async -> String {
        await runner.timings
    }
}

/// Owns the loaded models; one transcription at a time.
private actor GigaAMRunner {
    private struct Models {
        let encoder: MLModel
        let decoder: MLModel
        let joint: MLModel
        let pieces: [String]
    }

    /// The prediction network's memory, and how many tokens it has taken.
    private struct DecoderState {
        var hidden: MLMultiArray
        var cell: MLMultiArray
        var serial: Int
    }

    /// The model's fixed window: 30 s is 2999 mel frames.
    private static let windowFrames = 2999
    private static let blank = 1024
    private static let stateSize = 320

    private let computeUnits: MLComputeUnits
    private let idleUnload: TimeInterval
    /// Counts uses, so that a pending unload knows whether it is still due.
    private var useCount = 0
    private let frontend = MelFrontend()
    private let chunker = SpeechChunker()
    private var models: Models?
    /// Seconds spent on the features, the encoder and the decoding last time.
    private(set) var timings = ""

    init(computeUnits: MLComputeUnits, idleUnload: TimeInterval) {
        self.computeUnits = computeUnits
        self.idleUnload = idleUnload
    }

    var isLoaded: Bool { models != nil }

    /// The models leave memory once nothing has used them for `idleUnload` seconds.
    private func unloadWhenIdle() {
        useCount += 1
        let due = useCount
        let delay = idleUnload
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            self.unload(ifNotUsedSince: due)
        }
    }

    private func unload(ifNotUsedSince count: Int) {
        if useCount == count { models = nil }
    }

    func loadIfNeeded(from store: SpeechModelStore) async throws {
        defer { unloadWhenIdle() }
        guard models == nil else { return }
        let encoder = try await load("GigaAMv3Encoder", from: store)
        let decoder = try await load("GigaAMv3DecoderStep", from: store)
        let joint = try await load("GigaAMv3JointStep", from: store)
        let pieces = try JSONDecoder().decode([String].self, from: Data(contentsOf: store.url(for: "tokens.json")))
        guard pieces.count == Self.blank else { throw SpeechError.failed("tokens.json has \(pieces.count) pieces") }
        models = Models(encoder: encoder, decoder: decoder, joint: joint, pieces: pieces)
    }

    /// Compiles the package the first time; the compiled model is kept next to it.
    private func load(_ name: String, from store: SpeechModelStore) async throws -> MLModel {
        let compiled = store.directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let fresh = try await MLModel.compileModel(at: store.directory.appendingPathComponent("\(name).mlpackage", isDirectory: true))
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: fresh, to: compiled)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        do {
            return try MLModel(contentsOf: compiled, configuration: configuration)
        } catch {
            // A compiled model left by another macOS version: compile again next time.
            try? FileManager.default.removeItem(at: compiled)
            throw error
        }
    }

    func transcribe(_ samples: [Float]) throws -> String {
        guard let models else { throw SpeechError.unavailable }
        defer { unloadWhenIdle() }
        var texts: [String] = []
        timings = ""
        for range in chunker.split(samples) {
            let text = try transcribeWindow(Array(samples[range]), models: models)
            if !text.isEmpty { texts.append(text) }
        }
        return texts.joined(separator: " ")
    }

    private func transcribeWindow(_ window: [Float], models: Models) throws -> String {
        let frames = min(MelFrontend.frameCount(sampleCount: window.count), Self.windowFrames)
        guard frames > 0 else { return "" }
        // The whole 30 s window, silent after the end of the sound, as in the reference.
        var mark = Date()
        let features = frontend.logMel(window, frames: Self.windowFrames)
        let melTime = Date().timeIntervalSince(mark)
        mark = Date()
        let encoded = try models.encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "features": MLMultiArray(MLShapedArray<Float>(scalars: features, shape: [1, MelFrontend.melCount, Self.windowFrames])),
            "length": MLMultiArray(MLShapedArray<Int32>(scalars: [Int32(frames)], shape: [1])),
        ]))
        guard let states = encoded.featureValue(for: "encoded")?.multiArrayValue,
              let length = encoded.featureValue(for: "encoded_len")?.multiArrayValue,
              states.shape.count == 3 else {
            throw SpeechError.failed("the encoder's answer has no states")
        }
        let channels = states.shape[1].intValue
        let steps = states.shape[2].intValue
        let hidden = MLShapedArray<Float>(converting: states).scalars
        let encoderFrames = min(max(Int(length[0].doubleValue.rounded()), 0), steps)
        let encoderTime = Date().timeIntervalSince(mark)
        mark = Date()

        let zeros = [Float](repeating: 0, count: Self.stateSize)
        let start = DecoderState(
            hidden: MLMultiArray(MLShapedArray<Float>(scalars: zeros, shape: [1, 1, Self.stateSize])),
            cell: MLMultiArray(MLShapedArray<Float>(scalars: zeros, shape: [1, 1, Self.stateSize])),
            serial: 0
        )
        // Until a token is taken the prediction network answers the same: ask it once.
        var cached: (serial: Int, output: MLMultiArray, next: DecoderState)?
        let decoder = TransducerGreedyDecoder(blank: Self.blank)
        let tokens = try decoder.decode(frames: encoderFrames, start: start) { frame, last, state in
            if cached?.serial != state.serial {
                let predicted = try models.decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "token": MLMultiArray(MLShapedArray<Int32>(scalars: [Int32(last)], shape: [1, 1])),
                    "h_in": state.hidden,
                    "c_in": state.cell,
                ]))
                let next = try DecoderState(
                    hidden: Self.floats(predicted, "h_out", shape: [1, 1, Self.stateSize]),
                    cell: Self.floats(predicted, "c_out", shape: [1, 1, Self.stateSize]),
                    serial: state.serial + 1
                )
                cached = try (state.serial, Self.floats(predicted, "dec_out", shape: [1, Self.stateSize]), next)
            }
            guard let cached else { throw SpeechError.failed("the prediction network gave no answer") }
            let frameStates = (0..<channels).map { hidden[$0 * steps + frame] }
            let joined = try models.joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "enc_t": MLMultiArray(MLShapedArray<Float>(scalars: frameStates, shape: [1, channels])),
                "dec_t": cached.output,
            ]))
            guard let logits = joined.featureValue(for: "logits")?.multiArrayValue else {
                throw SpeechError.failed("the joint network gave no answer")
            }
            return (TransducerGreedyDecoder.argmax(MLShapedArray<Float>(converting: logits).scalars), cached.next)
        }
        timings += String(
            format: "mel %.2f s, encoder %.2f s, decoding %.2f s (%d frames, %d tokens); ",
            melTime, encoderTime, Date().timeIntervalSince(mark), encoderFrames, tokens.count
        )
        return PieceText.join(tokens, pieces: models.pieces)
    }

    /// An output as a float32 array of a known shape, whatever precision the model answered in.
    private static func floats(_ provider: any MLFeatureProvider, _ name: String, shape: [Int]) throws -> MLMultiArray {
        guard let array = provider.featureValue(for: name)?.multiArrayValue else {
            throw SpeechError.failed("the model's answer has no \(name)")
        }
        let scalars = MLShapedArray<Float>(converting: array).scalars
        guard scalars.count == shape.reduce(1, *) else { throw SpeechError.failed("\(name) has \(scalars.count) values") }
        return MLMultiArray(MLShapedArray<Float>(scalars: scalars, shape: shape))
    }
}

/// GigaAM when its model is on this Mac, Apple's recogniser until then (spec 7:
/// "while the model downloads"). The first press of the microphone starts the
/// download; it goes on in the background and its progress keeps being reported.
final class SpeechRouter: SpeechEngine, @unchecked Sendable {
    let id = "gigaam-or-apple"
    private let primary: GigaAMEngine
    private let fallback: any SpeechEngine
    private let lock = NSLock()
    private var installation: Task<Void, any Error>?

    init(primary: GigaAMEngine, fallback: any SpeechEngine) {
        self.primary = primary
        self.fallback = fallback
    }

    var isReady: Bool { primary.isReady || fallback.isReady }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if primary.isReady {
            // The model is on this Mac. It loads while the user speaks, so the
            // microphone opens at once.
            let primary = self.primary
            Task { await primary.warmUp() }
            return
        }
        let installing = startInstalling(progress: progress)
        do {
            try await fallback.prepare(progress: { _ in })
        } catch {
            // Nothing from Apple on this Mac: the only way is to wait for the model.
            guard let installing else { throw error }
            try await installing.value
        }
    }

    func transcribe(_ audio: AudioBuffer16k) async throws -> String {
        if primary.isReady {
            do {
                return try await primary.transcribe(audio)
            } catch SpeechError.nothingHeard {
                throw SpeechError.nothingHeard
            } catch {
                // A model that does not load must not take dictation away. The
                // fallback was not asked for its permission yet: the model was there.
                try await fallback.prepare(progress: { _ in })
            }
        }
        return try await fallback.transcribe(audio)
    }

    /// One download at a time; a failed one may be tried again at the next press.
    private func startInstalling(progress: @escaping @Sendable (Double) -> Void) -> Task<Void, any Error>? {
        guard primary.isSupported else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let installation { return installation }
        let primary = self.primary
        let task = Task { [weak self] in
            do {
                try await primary.prepare(progress: progress)
            } catch {
                self?.forgetInstallation()
                throw error
            }
        }
        installation = task
        return task
    }

    private func forgetInstallation() {
        lock.lock()
        installation = nil
        lock.unlock()
    }
}
