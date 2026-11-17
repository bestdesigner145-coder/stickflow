// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
import LocalModel
import StickflowCore

/// The model that takes dictation apart inside the app (spec 18.10 A1–A2):
/// where its file lives, and the one runner that holds it in memory. Which
/// model it is comes from `Resources/Models/structuring-model.json`, chosen
/// by the report in CI.
@MainActor
final class BuiltInModel {
    static let manifestName = "structuring-model"

    let store: ModelStore?
    /// "Qwen3 4B": how the settings name it.
    let name: String
    private let settings: LlamaSettings
    private var structurer: LocalStructurer?

    init(root: URL?, settings: LlamaSettings) {
        self.settings = settings
        if let root, let manifest = try? ModelManifest.bundled(named: Self.manifestName) {
            store = ModelStore(manifest: manifest, root: root)
            name = manifest.name ?? manifest.id
        } else {
            store = nil
            name = "—"
        }
    }

    /// The model's file; the manifest names exactly one.
    private var file: URL? {
        guard let store, let path = store.manifest.files.first?.path else { return nil }
        return store.url(for: path)
    }

    var isInstalled: Bool { store?.isInstalled ?? false }

    /// The structurer, once the model is on this Mac.
    var local: LocalStructurer? {
        guard isInstalled, let file else { return nil }
        if let structurer { return structurer }
        let made = LocalStructurer(runner: LlamaRunner(file: file, settings: settings), displayName: name)
        structurer = made
        return made
    }

    /// For the setup: how big it is and how to bring it.
    var model: ModelsSetup.Model {
        guard let store else { return .none }
        return ModelsSetup.Model(
            size: store.manifest.totalSize,
            isSupported: true,
            isInstalled: { store.isInstalled },
            bytesInPlace: { store.bytesInPlace },
            install: { progress in try await store.install(progress: progress) },
            remove: { [weak self] in self?.remove() }
        )
    }

    /// Loads the model and reads its rules ahead of the request.
    func prime() {
        guard let local else { return }
        Task { await local.prime() }
    }

    func remove() {
        structurer?.runner.unload()
        structurer = nil
        store?.remove()
    }
}
