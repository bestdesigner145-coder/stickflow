// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// The two models the app needs and whether they are here (spec 18.1, 18.10
/// A3): GigaAM, which hears, and the model that takes the dictation apart.
/// Neither is in the app; both come in one download, at the user's word —
/// "Download" in the first-launch window, or the first press of the
/// microphone (spec 0.8). Speech comes first: the microphone works as soon as
/// it is here, while the bigger model is still on its way.
@MainActor
final class ModelsSetup {
    enum State: Equatable {
        /// Both models are on this Mac.
        case ready
        /// Something is not here, and nobody has asked for it yet.
        case missing
        /// On its way: bytes in place of all there is to download.
        case downloading(received: Int64, total: Int64)
        /// The download broke; it may be started again.
        case failed
    }

    /// One model and how to bring it.
    struct Model {
        /// Bytes of the model.
        let size: Int64
        /// The model can run on this Mac at all.
        let isSupported: Bool
        let isInstalled: @MainActor () -> Bool
        /// Bytes already here, from a download that broke off.
        let bytesInPlace: @MainActor () -> Int64
        /// Downloads and checks the model, reporting the bytes in place.
        let install: @Sendable (@escaping @Sendable (Int64) -> Void) async throws -> Void
        /// Frees the disk.
        let remove: @MainActor () -> Void

        static let none = Model(
            size: 0, isSupported: false, isInstalled: { false }, bytesInPlace: { 0 }, install: { _ in }, remove: {}
        )

        /// For tests and the self-check: a model that is here.
        static let here = Model(
            size: 1, isSupported: true, isInstalled: { true }, bytesInPlace: { 1 }, install: { _ in }, remove: {}
        )
    }

    let speech: Model
    let structuring: Model
    private(set) var state: State = .missing
    private var received: [Int64] = [0, 0]
    private var observers: [() -> Void] = []
    private var task: Task<Void, Never>?
    #if DEBUG
    private var forced: (speech: Bool, structuring: Bool)?
    #endif

    init(speech: Model, structuring: Model) {
        self.speech = speech
        self.structuring = structuring
        state = isComplete ? .ready : .missing
    }

    /// For tests and the self-check: everything is here.
    static func ready() -> ModelsSetup {
        ModelsSetup(speech: .here, structuring: .here)
    }

    private var models: [Model] { [speech, structuring] }

    /// Every model this Mac can run is here.
    private var isComplete: Bool {
        models.allSatisfy { !$0.isSupported || $0.isInstalled() }
    }

    /// The microphone may be offered.
    var isSpeechReady: Bool {
        #if DEBUG
        if let forced { return forced.speech }
        #endif
        return speech.isSupported && speech.isInstalled()
    }

    /// The built-in model can take dictation apart.
    var isStructuringReady: Bool {
        #if DEBUG
        if let forced { return forced.structuring }
        #endif
        return structuring.isSupported && structuring.isInstalled()
    }

    /// GigaAM needs macOS 15; there is no other recogniser (spec 18.1).
    var isSpeechSupported: Bool { speech.isSupported }

    /// Bytes of everything this Mac will download, for "3 GB".
    var totalBytes: Int64 {
        models.filter(\.isSupported).reduce(0) { $0 + $1.size }
    }

    /// How far each model is, 0…100, for "Getting voice ready… 34 %".
    var speechPercent: Int { percent(of: 0) }
    var structuringPercent: Int { percent(of: 1) }

    private func percent(of index: Int) -> Int {
        let model = models[index]
        if model.isInstalled() { return 100 }
        guard model.size > 0 else { return 0 }
        return min(Int(Double(received[index]) / Double(model.size) * 100), 99)
    }

    /// Called on every change.
    func observe(_ handler: @escaping () -> Void) {
        observers.append(handler)
    }

    /// Starts the download of whatever is missing. Only ever called from a
    /// button or the microphone (spec 0.8).
    func start() {
        guard state == .missing || state == .failed else { return }
        let total = totalBytes
        received = models.map { $0.isInstalled() ? $0.size : $0.bytesInPlace() }
        set(.downloading(received: received.reduce(0, +), total: total))
        let pending = models.indices.filter { models[$0].isSupported && !models[$0].isInstalled() }
        let installs = pending.map { (index: $0, install: models[$0].install) }
        task = Task { [weak self] in
            do {
                for item in installs {
                    try await item.install { [weak self] bytes in
                        Task { @MainActor [weak self] in
                            self?.didReceive(bytes, for: item.index)
                        }
                    }
                    self?.didFinish(item.index)
                }
                self?.set(.ready)
            } catch {
                self?.set(.failed)
            }
        }
    }

    /// The settings' "Delete" for the built-in model (spec 18.10 C1).
    func removeStructuringModel() {
        if case .downloading = state { return }
        structuring.remove()
        received[1] = 0
        set(isComplete ? .ready : .missing)
        notify()
    }

    private func didReceive(_ bytes: Int64, for index: Int) {
        guard case let .downloading(_, total) = state else { return }
        received[index] = bytes
        let now = received.reduce(0, +)
        // Ten megabytes are enough for the eye.
        if case let .downloading(shown, _) = state, abs(now - shown) < 10_000_000 { return }
        set(.downloading(received: min(now, total), total: total))
    }

    private func didFinish(_ index: Int) {
        received[index] = models[index].size
        // The microphone comes as soon as speech is here.
        notify()
    }

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        notify()
    }

    private func notify() {
        for observer in observers {
            observer()
        }
    }

    #if DEBUG
    /// For snapshots and the self-check.
    func setStateForTesting(_ new: State, speech: Bool? = nil, structuring: Bool? = nil) {
        if let speech, let structuring { forced = (speech, structuring) } else { forced = nil }
        if new == state { notify() } else { set(new) }
    }
    #endif
}
