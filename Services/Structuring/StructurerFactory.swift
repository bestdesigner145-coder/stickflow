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

/// Which structurer the settings ask for (spec 8.1).
enum StructurerChoice: String, CaseIterable, Sendable {
    case rules
    case ollama
    case openAICompatible = "openai-compatible"
    case claude

    var label: String {
        switch self {
        case .rules: "Rules (no model)"
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI-compatible"
        case .claude: "Claude API"
        }
    }

    var needsKey: Bool { self == .openAICompatible || self == .claude }
}

@MainActor
enum StructurerFactory {
    /// The structurer the settings describe. Settings that do not add up (no
    /// model, a host that is not a URL) give the rules, which always work.
    static func make(from preferences: Preferences, network: any Network) -> any Structurer {
        func url(_ text: String) -> URL? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
            return url
        }
        func name(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        switch preferences.structurerChoice {
        case .rules:
            return RuleStructurer()
        case .ollama:
            guard let host = url(preferences.ollamaHost), let model = name(preferences.ollamaModel) else { return RuleStructurer() }
            return ChatStructurer(provider: .ollama(host: host, model: model), network: network)
        case .openAICompatible:
            guard let base = url(preferences.openAIBaseURL), let model = name(preferences.openAIModel) else { return RuleStructurer() }
            let account = StructurerChoice.openAICompatible.rawValue
            let provider = ChatProvider.openAICompatible(baseURL: base, model: model)
            return ChatStructurer(provider: provider, network: network) { KeychainStore.read(account) }
        case .claude:
            let account = StructurerChoice.claude.rawValue
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
