// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import SnapshotTesting
@testable import Stickflow
import StickflowCore
import SwiftUI
import XCTest

/// The settings of sorting, with no empty field (spec 18.10 C1).
@MainActor
final class SettingsSnapshotTests: XCTestCase {
    private struct Offline: Network {
        func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
            throw URLError(.notConnectedToInternet)
        }
    }

    private func model(_ choice: StructurerChoice) -> StructuringSettingsModel {
        let defaults = UserDefaults(suiteName: "settings-snapshot-\(UUID().uuidString)") ?? .standard
        let preferences = Preferences(defaults: defaults)
        preferences.structurerChoice = choice
        let keys = StructuringSettingsModel.KeyStore(read: { $0 == "claude" ? "sk-ant-example-1a2b" : nil }, save: { _, _ in true })
        let model = StructuringSettingsModel(
            preferences: preferences, models: .ready(), network: Offline(), keys: keys, builtInName: "Gemma 3 4B"
        )
        model.builtInBytes = 2_500_000_000
        model.lists[.claude] = [ChatProvider.claudeDefaultModel]
        return model
    }

    func testStructuringSettings() {
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for choice in [StructurerChoice.local, .claude, .chatGPT, .ollama] {
                let settings = model(choice)
                if choice == .ollama { settings.server = .notRunning }
                if choice == .claude { settings.check = .works }
                let host = NSHostingView(rootView: StructuringSettingsView(model: settings))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: 460, height: max(host.fittingSize.height, 120))
                assertSnapshot(of: SnapshotRenderer.image(of: host), as: SnapshotRenderer.strategy, named: "\(theme)-\(choice.rawValue)")
            }
        }
    }

    /// The model the settings ask for, for each provider (spec 18.10 C1).
    func testModelsAreReadFromEachProvidersList() {
        let openAI = Data(#"{"data":[{"id":"gpt-5-mini"},{"id":"gpt-5"}]}"#.utf8)
        XCTAssertEqual(StructuringSettingsModel.parseModels(openAI, ollama: false), ["gpt-5", "gpt-5-mini"])
        let ollama = Data(#"{"models":[{"name":"qwen3:4b"},{"name":"gemma3:4b"}]}"#.utf8)
        XCTAssertEqual(StructuringSettingsModel.parseModels(ollama, ollama: true), ["gemma3:4b", "qwen3:4b"])
        XCTAssertEqual(StructuringSettingsModel.parseModels(Data("nope".utf8), ollama: true), [])
        XCTAssertEqual(StructuringSettingsModel.describe(.missingKey, provider: .claude), L10n.structureNoKey("Claude"))
        XCTAssertEqual(StructuringSettingsModel.describe(.rejectedKey, provider: .chatGPT), L10n.structureBadKey("ChatGPT"))
    }

    /// The window "Voice → tasks" speaks of gigabytes as people do.
    func testGigabytes() {
        XCTAssertEqual(ModelSetupView.gigabytes(2_950_000_000).filter(\.isNumber), "3")
        XCTAssertEqual(ModelSetupView.gigabytes(1_230_000_000).filter(\.isNumber), "12")
        XCTAssertEqual(ModelSetupView.gigabytes(0), "0")
        XCTAssertEqual(ModelSetupView.wholeGigabytes(2_935_000_000), "3", "the whole download is said as in spec 18.10 A3")
        XCTAssertEqual(ModelSetupView.wholeGigabytes(445_000_000).filter(\.isNumber), "4")
    }
}
