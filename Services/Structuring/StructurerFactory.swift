// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import Foundation
import Security
import StickflowCore

/// The real network. Nothing in the app reaches it except through a structurer
/// the user has chosen and the speech model's download (spec 0.8).
struct URLSessionNetwork: Network {
    private static let session = URLSession(configuration: .ephemeral)
    /// Seconds a request may take; the app's own limits (spec 8.1) are shorter.
    var timeout: TimeInterval = 60

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        var request = request
        request.timeoutInterval = timeout
        let (data, response) = try await Self.session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// API keys live in the Keychain and nowhere else (spec 8.1).
enum KeychainStore {
    private static let service = "io.github.stickflow.keys"

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty value removes the key.
    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        SecItemDelete(base(account) as CFDictionary)
        guard !value.isEmpty else { return true }
        var attributes = base(account)
        attributes[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func has(_ account: String) -> Bool {
        !(read(account) ?? "").isEmpty
    }
}

/// Which structurer the settings ask for, in the order of spec 18.10 A4. The
/// rules are not among them: they are only what is left when the built-in
/// model fails.
enum StructurerChoice: String, CaseIterable, Sendable {
    case local
    case claude
    case chatGPT = "openai"
    case openAICompatible = "openai-compatible"
    case ollama

    static let chatGPTDefaultModel = "gpt-5-mini"
    static let chatGPTBaseURL = "https://api.openai.com"
    static let deepSeekBaseURL = "https://api.deepseek.com"
    static let deepSeekModel = "deepseek-chat"

    var label: String {
        switch self {
        case .local: L10n.providerLocal
        case .claude: "Claude"
        case .chatGPT: "ChatGPT / OpenAI"
        case .openAICompatible: L10n.providerCompatible
        case .ollama: "Ollama / LM Studio"
        }
    }

    /// How the provider is named in a sentence: "Нет ключа Claude".
    var name: String {
        switch self {
        case .local: L10n.providerLocal
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        case .openAICompatible: "DeepSeek"
        case .ollama: "Ollama"
        }
    }

    var needsKey: Bool { self == .claude || self == .chatGPT || self == .openAICompatible }

    /// The key's name in the Keychain.
    var account: String { rawValue }

    /// What a key of this provider starts with, for the empty field.
    var keyPlaceholder: String { self == .claude ? "sk-ant-…" : "sk-…" }
}

/// The built-in model, or what stands in for it (spec 18.10): the model
/// itself once it is here; "still downloading" before; the rules when the
/// model would not load or fell over.
struct BuiltInStructurer: Structurer {
    let id = "local"
    let displayName = L10n.providerLocal
    let isLocal = true
    /// `nil` while the model is not on this Mac.
    let model: (any Structurer)?
    /// How much of the model is here, for "still downloading — 64 %".
    let percent: Int

    func health() async -> StructurerHealth {
        await model?.health() ?? .unavailable("the model is not downloaded")
    }

    func structure(_ request: StructureRequest) async throws -> NotePlan {
        guard let model else { throw StructurerError.modelDownloading(percent) }
        do {
            return try await model.structure(request)
        } catch let error as StructurerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The model would not load or broke down: the rules, the fallback of spec 18.10 A4.
            let plan = try await RuleStructurer().structure(request)
            return plan.titled(apartFrom: request.takenTitles, at: request.now)
        }
    }
}

/// A provider whose settings lack something the user must choose: it says what.
struct UnconfiguredStructurer: Structurer {
    let id: String
    let displayName: String
    let isLocal: Bool
    let error: StructurerError

    func health() async -> StructurerHealth {
        .unavailable("\(error)")
    }

    func structure(_ request: StructureRequest) async throws -> NotePlan {
        throw error
    }
}

@MainActor
enum StructurerFactory {
    /// The structurer the settings describe. Settings that do not add up give
    /// one that says what is missing, never the rules in silence (spec 18.10 C1).
    static func make(from preferences: Preferences, network: any Network, builtIn: @autoclosure () -> any Structurer) -> any Structurer {
        func url(_ text: String) -> URL? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
            return url
        }
        func name(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let choice = preferences.structurerChoice
        let account = choice.account
        let missing = UnconfiguredStructurer(id: choice.rawValue, displayName: choice.name, isLocal: choice == .ollama, error: .noModel)
        switch choice {
        case .local:
            return builtIn()
        case .ollama:
            guard let host = url(preferences.ollamaHost), let model = name(preferences.ollamaModel) else { return missing }
            if preferences.localServerSpeaksOpenAI {
                return ChatStructurer(provider: .openAICompatible(baseURL: host, model: model), network: network)
            }
            return ChatStructurer(provider: .ollama(host: host, model: model), network: network)
        case .openAICompatible:
            guard let base = url(preferences.openAIBaseURL), let model = name(preferences.openAIModel) else { return missing }
            let provider = ChatProvider.openAICompatible(baseURL: base, model: model)
            return ChatStructurer(provider: provider, network: network) { KeychainStore.read(account) }
        case .chatGPT:
            guard let base = url(StructurerChoice.chatGPTBaseURL), let model = name(preferences.chatGPTModel) else { return missing }
            let provider = ChatProvider.openAICompatible(baseURL: base, model: model)
            return ChatStructurer(provider: provider, network: network) { KeychainStore.read(account) }
        case .claude:
            let model = name(preferences.claudeModel) ?? ChatProvider.claudeDefaultModel
            return ChatStructurer(provider: .claude(model: model), network: network) { KeychainStore.read(account) }
        }
    }
}

/// Spec 8.1: a cloud provider is never used without being asked about. The
/// question comes before the first request to it.
@MainActor
enum CloudConsent {
    static func ask(provider name: String) -> (allowed: Bool, remember: Bool) {
        let alert = NSAlert()
        alert.messageText = L10n.cloudConsentTitle(provider: name)
        alert.informativeText = L10n.cloudConsentInfo
        alert.addButton(withTitle: L10n.cloudConsentContinue)
        alert.addButton(withTitle: L10n.cloudConsentCancel)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.cloudConsentRemember
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return (response == .alertFirstButtonReturn, alert.suppressionButton?.state == .on)
    }
}
