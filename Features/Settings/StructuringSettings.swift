// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore
import SwiftUI

/// What the "Sorting" settings show and do (spec 18.10 C1): no field is left
/// empty, a list stands where there is something to choose from, a key says
/// whether it is there and can be checked.
@MainActor
final class StructuringSettingsModel: ObservableObject {
    enum Check: Equatable {
        case idle
        case checking
        case works
        case failed(String)
    }

    enum Server: Equatable {
        case unknown
        case asking
        case running
        case notRunning
    }

    @Published var choice: StructurerChoice {
        didSet { save { $0.structurerChoice = choice } }
    }

    @Published var claudeModel: String {
        didSet { save { $0.claudeModel = claudeModel } }
    }

    @Published var chatGPTModel: String {
        didSet { save { $0.chatGPTModel = chatGPTModel } }
    }

    @Published var compatibleBaseURL: String {
        didSet { save { $0.openAIBaseURL = compatibleBaseURL } }
    }

    @Published var compatibleModel: String {
        didSet { save { $0.openAIModel = compatibleModel } }
    }

    @Published var ollamaHost: String {
        didSet { save { $0.ollamaHost = ollamaHost } }
    }

    @Published var ollamaModel: String {
        didSet { save { $0.ollamaModel = ollamaModel } }
    }

    /// Models each provider offers, once asked.
    @Published var lists: [StructurerChoice: [String]] = [:]
    @Published var keyDraft = ""
    /// The last four characters of each saved key; `nil` — there is no key.
    @Published var keyEnds: [StructurerChoice: String] = [:]
    @Published var check = Check.idle
    @Published var server = Server.unknown
    /// Bytes of the built-in model on disk; 0 — it is not here.
    @Published var builtInBytes: Int64 = 0
    @Published var builtInName = ""

    private let preferences: Preferences
    private let models: ModelsSetup
    private let network: any Network
    private let keys: KeyStore

    /// Where keys are kept; the Keychain, or a dictionary in tests.
    struct KeyStore {
        var read: @MainActor (String) -> String?
        var save: @MainActor (String, String) -> Bool

        static let keychain = KeyStore(read: { KeychainStore.read($0) }, save: { KeychainStore.save($1, account: $0) })
    }

    init(preferences: Preferences, models: ModelsSetup, network: any Network, keys: KeyStore = .keychain, builtInName: String) {
        self.preferences = preferences
        self.models = models
        self.network = network
        self.keys = keys
        self.builtInName = builtInName
        choice = preferences.structurerChoice
        claudeModel = preferences.claudeModel
        chatGPTModel = preferences.chatGPTModel
        compatibleBaseURL = preferences.openAIBaseURL
        compatibleModel = preferences.openAIModel
        ollamaHost = preferences.ollamaHost
        ollamaModel = preferences.ollamaModel
        refreshKeys()
        refreshBuiltIn()
        models.observe { [weak self] in self?.refreshBuiltIn() }
    }

    private func save(_ change: (Preferences) -> Void) {
        change(preferences)
        preferences.persist()
    }

    func refreshKeys() {
        for choice in StructurerChoice.allCases where choice.needsKey {
            keyEnds[choice] = keys.read(choice.account).flatMap { $0.isEmpty ? nil : String($0.suffix(4)) }
        }
    }

    func refreshBuiltIn() {
        builtInBytes = models.isStructuringReady ? models.structuring.size : 0
    }

    // MARK: Keys

    var canSaveKey: Bool { !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, keys.save(choice.account, key) else { return }
        keyDraft = ""
        refreshKeys()
        check = .idle
    }

    func deleteKey() {
        _ = keys.save(choice.account, "")
        refreshKeys()
        check = .idle
    }

    /// A request that costs nothing: the list of models. It also fills the list (spec 18.10 C1, "Check").
    func checkKey() async {
        guard let key = keys.read(choice.account), !key.isEmpty else {
            check = .failed(L10n.settingsNoKey)
            return
        }
        check = .checking
        let provider = choice
        do {
            let found = try await Self.models(of: provider, key: key, base: compatibleBaseURL, network: network)
            lists[provider] = found
            pickDefault(for: provider, from: found)
            check = .works
        } catch let error as StructurerError {
            check = .failed(Self.describe(error, provider: provider))
        } catch {
            check = .failed(error.localizedDescription)
        }
    }

    // MARK: Ollama

    /// Asks the server which models it has; picks qwen3:4b, or the first (spec 18.10 C1).
    /// Ollama answers at `/api/tags`; LM Studio speaks OpenAI's language at `/v1/models`.
    func askOllama() async {
        server = .asking
        var found: [String]?
        if let names = try? await Self.models(of: .ollama, key: nil, base: ollamaHost, network: network) {
            found = names
            save { $0.localServerSpeaksOpenAI = false }
        } else if let names = try? await Self.models(of: .openAICompatible, key: nil, base: ollamaHost, network: network) {
            found = names
            save { $0.localServerSpeaksOpenAI = true }
        }
        guard let found else {
            server = .notRunning
            return
        }
        lists[.ollama] = found
        server = .running
        if !found.contains(ollamaModel) {
            ollamaModel = found.first { $0 == "qwen3:4b" } ?? found.first ?? ""
        }
    }

    func deleteBuiltIn() {
        models.removeStructuringModel()
        refreshBuiltIn()
    }

    func downloadBuiltIn() {
        models.start()
    }

    private func pickDefault(for provider: StructurerChoice, from found: [String]) {
        switch provider {
        case .claude:
            if !found.contains(claudeModel) {
                claudeModel = found.first { $0 == ChatProvider.claudeDefaultModel }
                    ?? found.first { $0.contains("haiku") } ?? found.first ?? claudeModel
            }
        case .chatGPT:
            if !found.contains(chatGPTModel) {
                chatGPTModel = found.first { $0 == StructurerChoice.chatGPTDefaultModel }
                    ?? found.first { $0.hasPrefix("gpt") } ?? chatGPTModel
            }
        case .openAICompatible:
            if !found.contains(compatibleModel), let first = found.first { compatibleModel = first }
        case .local, .ollama:
            break
        }
    }

    /// The models a provider offers.
    static func models(of provider: StructurerChoice, key: String?, base: String, network: any Network) async throws -> [String] {
        var request: URLRequest
        switch provider {
        case .claude:
            guard let url = URL(string: "https://api.anthropic.com/v1/models?limit=100") else { return [] }
            request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .chatGPT, .openAICompatible:
            let root = provider == .chatGPT ? StructurerChoice.chatGPTBaseURL : base
            guard let url = URL(string: root.trimmingCharacters(in: .whitespacesAndNewlines))?.appendingPathComponent("v1/models") else {
                throw StructurerError.noModel
            }
            request = URLRequest(url: url)
            if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .ollama:
            guard let url = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines))?.appendingPathComponent("api/tags") else {
                throw StructurerError.unavailable(0)
            }
            request = URLRequest(url: url)
        case .local:
            return []
        }
        let answer: (data: Data, status: Int)
        do {
            answer = try await network.send(request)
        } catch let error as URLError {
            throw ChatStructurer.failure(error)
        }
        guard (200..<300).contains(answer.status) else {
            throw ChatStructurer.failure(status: answer.status, body: String(bytes: answer.data, encoding: .utf8) ?? "")
        }
        return parseModels(answer.data, ollama: provider == .ollama)
    }

    /// `{"data":[{"id":…}]}` from Claude and OpenAI, `{"models":[{"name":…}]}` from Ollama.
    static func parseModels(_ data: Data, ollama: Bool) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let entries = (object[ollama ? "models" : "data"] as? [[String: Any]]) ?? []
        return entries.compactMap { $0[ollama ? "name" : "id"] as? String }.sorted()
    }

    /// The reason in the words of spec 18.10 C2.
    static func describe(_ error: StructurerError, provider: StructurerChoice) -> String {
        switch error {
        case .missingKey: L10n.structureNoKey(provider.name)
        case .rejectedKey: L10n.structureBadKey(provider.name)
        case .offline: L10n.settingsOffline
        case .noCredit: L10n.structureNoCredit(provider.name)
        case .noModel: L10n.structureNoModel(provider.name)
        default: L10n.settingsNoAnswer(provider.name)
        }
    }
}

/// The settings window, "Sorting" for now: the rest arrives in stage 4.
struct StructuringSettingsView: View {
    @ObservedObject var model: StructuringSettingsModel

    var body: some View {
        Form {
            Section {
                Picker(selection: $model.choice) {
                    ForEach(StructurerChoice.allCases, id: \.self) { choice in
                        Text(verbatim: choice.label).tag(choice)
                    }
                } label: {
                    Text(L10n.settingsProvider)
                }
                .pickerStyle(.menu)
            } footer: {
                Text(model.choice == .local ? L10n.settingsLocalNote : L10n.settingsCloudNote)
                    .foregroundStyle(.secondary)
            }
            details
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: model.choice) {
            if model.choice == .ollama, model.server == .unknown { await model.askOllama() }
        }
    }

    @ViewBuilder private var details: some View {
        switch model.choice {
        case .local:
            Section {
                LabeledContent {
                    Text(verbatim: model.builtInName)
                } label: {
                    Text(L10n.settingsModel)
                }
                LabeledContent {
                    if model.builtInBytes > 0 {
                        HStack {
                            Text(verbatim: ModelSetupView.gigabytes(model.builtInBytes) + " " + L10n.settingsGB)
                            Button(role: .destructive) { model.deleteBuiltIn() } label: { Text(L10n.settingsDelete) }
                        }
                    } else {
                        HStack {
                            Text(L10n.settingsNotDownloaded).foregroundStyle(.secondary)
                            Button { model.downloadBuiltIn() } label: { Text(L10n.setupDownload) }
                        }
                    }
                } label: {
                    Text(L10n.settingsSize)
                }
            }
        case .claude:
            modelPicker(selection: $model.claudeModel, provider: .claude)
            keySection
        case .chatGPT:
            modelPicker(selection: $model.chatGPTModel, provider: .chatGPT)
            keySection
        case .openAICompatible:
            Section {
                TextField(text: $model.compatibleBaseURL, prompt: Text(verbatim: StructurerChoice.deepSeekBaseURL)) {
                    Text(L10n.settingsAddress)
                }
                modelRow(selection: $model.compatibleModel, provider: .openAICompatible)
            }
            keySection
        case .ollama:
            Section {
                TextField(text: $model.ollamaHost, prompt: Text(verbatim: "http://localhost:11434")) {
                    Text(L10n.settingsAddress)
                }
                switch model.server {
                case .notRunning:
                    LabeledContent {
                        HStack {
                            Link(destination: URL(string: "https://ollama.com/download")!) { Text(L10n.settingsHowToStart) }
                            Button { Task { await model.askOllama() } } label: { Text(L10n.settingsAskAgain) }
                        }
                    } label: {
                        Text(L10n.settingsOllamaNotRunning).foregroundStyle(.red)
                    }
                case .asking:
                    LabeledContent {
                        ProgressView().controlSize(.small)
                    } label: {
                        Text(L10n.settingsModel)
                    }
                default:
                    modelRow(selection: $model.ollamaModel, provider: .ollama)
                }
            } footer: {
                Text(L10n.settingsOllamaNote).foregroundStyle(.secondary)
            }
        }
    }

    private func modelPicker(selection: Binding<String>, provider: StructurerChoice) -> some View {
        Section {
            modelRow(selection: selection, provider: provider)
        }
    }

    /// A list when there is one; the current name stays in it, so the field is never empty.
    private func modelRow(selection: Binding<String>, provider: StructurerChoice) -> some View {
        let listed = model.lists[provider] ?? []
        let names = listed.contains(selection.wrappedValue) || selection.wrappedValue.isEmpty ? listed : [selection.wrappedValue] + listed
        return Picker(selection: selection) {
            ForEach(names, id: \.self) { name in
                Text(verbatim: name).tag(name)
            }
        } label: {
            Text(L10n.settingsModel)
        }
        .pickerStyle(.menu)
        .disabled(names.isEmpty)
    }

    private var keySection: some View {
        Section {
            LabeledContent {
                if let end = model.keyEnds[model.choice] {
                    Text(L10n.settingsKeySaved(end))
                } else {
                    Text(L10n.settingsNoKey).foregroundStyle(.secondary)
                }
            } label: {
                Text(L10n.settingsKey)
            }
            HStack {
                // Spec 18.10 C1: a visible field, with what a key looks like.
                TextField(text: $model.keyDraft, prompt: Text(verbatim: model.choice.keyPlaceholder)) {
                    Text(L10n.settingsNewKey)
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                Button { model.saveKey() } label: { Text(L10n.settingsSave) }
                    .disabled(!model.canSaveKey)
            }
            HStack {
                Button { Task { await model.checkKey() } } label: { Text(L10n.settingsCheck) }
                    .disabled(model.keyEnds[model.choice] == nil || model.check == .checking)
                checkResult
                Spacer()
                if model.keyEnds[model.choice] != nil {
                    Button(role: .destructive) { model.deleteKey() } label: { Text(L10n.settingsDeleteKey) }
                }
            }
        } footer: {
            Text(L10n.settingsKeyNote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var checkResult: some View {
        switch model.check {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .works: Text(L10n.settingsKeyWorks).foregroundStyle(.green)
        case let .failed(reason): Text(verbatim: reason).foregroundStyle(.red)
        }
    }
}

/// The window that holds the settings.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: StructuringSettingsModel

    init(model: StructuringSettingsModel) {
        self.model = model
    }

    func show() {
        model.refreshKeys()
        model.refreshBuiltIn()
        let window = self.window ?? makeWindow()
        self.window = window
        WindowPresenter.present(window)
    }

    /// The window, once it has been shown; for the self-check.
    var shownWindow: NSWindow? { window }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: StructuringSettingsView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = L10n.settingsTitle
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        return window
    }
}
