// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// Whether dictation can be used yet (spec 18.1). The speech model is not in
/// the app: it is downloaded once, at the first launch, by the user's word.
/// Until it is on this Mac there is no microphone anywhere, only this state.
@MainActor
final class SpeechSetup {
    enum State: Equatable {
        /// The model is on this Mac.
        case ready
        /// Not here, and nobody has asked for it yet.
        case missing
        /// On its way; the percentage of bytes in place.
        case downloading(Int)
        /// The download broke; it may be started again.
        case failed
        /// This macOS cannot run the model (it needs macOS 15).
        case unsupported
    }

    typealias Install = @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void

    private(set) var state: State
    /// Megabytes to download, for the texts.
    let megabytes: Int
    private let install: Install
    private var observers: [() -> Void] = []
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - isInstalled: the model is on this Mac already.
    ///   - install: downloads and checks the model, reporting 0…1.
    init(isSupported: Bool, isInstalled: Bool, megabytes: Int, install: @escaping Install) {
        self.megabytes = megabytes
        self.install = install
        state = !isSupported ? .unsupported : (isInstalled ? .ready : .missing)
    }

    /// For tests and the self-check: nothing to download.
    static func ready() -> SpeechSetup {
        SpeechSetup(isSupported: true, isInstalled: true, megabytes: 0) { _ in }
    }

    var isReady: Bool { state == .ready }

    /// Called on every change of `state`.
    func observe(_ handler: @escaping () -> Void) {
        observers.append(handler)
    }

    /// Starts the download. Only ever called from a button (spec 0.8).
    func start() {
        guard state == .missing || state == .failed else { return }
        set(.downloading(0))
        let install = self.install
        task = Task { [weak self] in
            do {
                try await install { [weak self] value in
                    Task { @MainActor [weak self] in
                        self?.didProgress(value)
                    }
                }
                self?.set(.ready)
            } catch {
                self?.set(.failed)
            }
        }
    }

    private func didProgress(_ value: Double) {
        guard case let .downloading(shown) = state else { return }
        // 100 is said by `ready`, once the files have been checked.
        let percent = min(max(Int(value * 100), 0), 99)
        if percent != shown { set(.downloading(percent)) }
    }

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        for observer in observers {
            observer()
        }
    }

    #if DEBUG
    /// For snapshots and the self-check.
    func setStateForTesting(_ new: State) {
        set(new)
    }
    #endif
}
