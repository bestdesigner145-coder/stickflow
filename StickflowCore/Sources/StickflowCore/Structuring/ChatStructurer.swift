// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// The network, behind a protocol: tests replace it, and the privacy check can
/// count every request (spec 17.3).
public protocol Network: Sendable {
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
}

/// A service that answers chat requests, and the way it wants to be spoken to
/// (spec 8.1). Each case knows how to build its request and read its answer.
public enum ChatProvider: Equatable, Sendable {
    /// A local Ollama server or LM Studio's Ollama-compatible port.
    case ollama(host: URL, model: String)
    /// Anything that speaks `/v1/chat/completions`: LM Studio, a server of one's own, a cloud.
    case openAICompatible(baseURL: URL, model: String)
    /// Anthropic's Messages API.
    case claude(model: String)

    public static let claudeDefaultModel = "claude-haiku-5-5"
    static let claudeEndpoint = "https://api.anthropic.com/v1/messages"
    static let claudeVersion = "2023-06-01"

    public var id: String {
        switch self {
        case .ollama: "ollama"
        case .openAICompatible: "openai-compatible"
        case .claude: "claude"
        }
    }

    public var displayName: String {
        switch self {
        case let .ollama(_, model): "Ollama (\(model))"
        case let .openAICompatible(baseURL, model): "\(baseURL.host ?? "OpenAI-compatible") (\(model))"
        case let .claude(model): "Claude (\(model))"
        }
    }

    /// The text stays on this Mac: the server is this Mac itself.
    public var isLocal: Bool {
        switch self {
        case let .ollama(host, _): Self.isLoopback(host)
        case let .openAICompatible(baseURL, _): Self.isLoopback(baseURL)
        case .claude: false
        }
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// - Parameters:
    ///   - structured: ask the server to hold the answer to the schema, where it can.
    ///   - apiKey: the user's key; never stored here.
    public func request(messages: [ChatMessage], apiKey: String?, structured: Bool = true) throws -> URLRequest {
        let url: URL
        var body: [String: Any]
        var headers = ["Content-Type": "application/json"]
        let turns = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let schema = try JSONSerialization.jsonObject(with: Data(StructurePrompt.schema.utf8))

        switch self {
        case let .ollama(host, model):
            url = host.appendingPathComponent("api/chat")
            body = ["model": model, "messages": turns, "stream": false, "options": ["temperature": 0.2]]
            if structured { body["format"] = schema }
        case let .openAICompatible(baseURL, model):
            url = baseURL.appendingPathComponent("v1/chat/completions")
            body = ["model": model, "messages": turns, "temperature": 0.2, "stream": false]
            if structured {
                let named: [String: Any] = ["name": "note_plan", "strict": true, "schema": schema]
                body["response_format"] = ["type": "json_schema", "json_schema": named] as [String: Any]
            }
            if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        case let .claude(model):
            guard let endpoint = URL(string: Self.claudeEndpoint), let apiKey, !apiKey.isEmpty else {
                throw StructurerError.notConfigured
            }
            url = endpoint
            // The Messages API takes the system text apart from the turns.
            let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
            let rest = messages.filter { $0.role != .system }.map { ["role": $0.role.rawValue, "content": $0.content] }
            body = ["model": model, "max_tokens": 2048, "system": system, "messages": rest]
            headers["x-api-key"] = apiKey
            headers["anthropic-version"] = Self.claudeVersion
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// The model's words out of the service's answer.
    public func text(from data: Data) throws -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        var text: String?
        switch self {
        case .ollama:
            text = (object?["message"] as? [String: Any])?["content"] as? String
        case .openAICompatible:
            let choice = (object?["choices"] as? [[String: Any]])?.first
            text = (choice?["message"] as? [String: Any])?["content"] as? String
        case .claude:
            // Thinking and other blocks may come first: only the text counts.
            let blocks = (object?["content"] as? [[String: Any]]) ?? []
            let parts = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            text = parts.isEmpty ? nil : parts.joined()
        }
        guard let text, !text.isEmpty else { throw StructurerError.invalidAnswer }
        return text
    }
}

/// A structurer that asks a language model over HTTP (spec 8.1): Ollama, an
/// OpenAI-compatible server, Claude. One answer that cannot be read is asked
/// for again with a reminder about the format; a second one is a failure (8.3).
public struct ChatStructurer: Structurer {
    public let provider: ChatProvider
    private let network: any Network
    /// Read at the moment of the request, so that a key is never kept in memory longer.
    private let apiKey: @Sendable () -> String?

    public init(provider: ChatProvider, network: any Network, apiKey: @escaping @Sendable () -> String? = { nil }) {
        self.provider = provider
        self.network = network
        self.apiKey = apiKey
    }

    public var id: String { provider.id }
    public var displayName: String { provider.displayName }
    public var isLocal: Bool { provider.isLocal }

    public func health() async -> StructurerHealth {
        if case .claude = provider, (apiKey() ?? "").isEmpty {
            return .unavailable("no API key")
        }
        return .ready
    }

    public func structure(_ request: StructureRequest) async throws -> NotePlan {
        let messages = StructurePrompt.messages(for: request)
        let answer = try await ask(messages)
        if let plan = try? PlanParser.parse(answer) {
            return plan
        }
        return try await PlanParser.parse(ask(StructurePrompt.retry(messages, after: answer)))
    }

    private func ask(_ messages: [ChatMessage]) async throws -> String {
        let key = apiKey()
        var response = try await network.send(provider.request(messages: messages, apiKey: key))
        if response.status == 400 || response.status == 422, provider.id != "claude" {
            // A server that does not know schema-bound answers: ask plainly, the prompt names the format.
            response = try await network.send(provider.request(messages: messages, apiKey: key, structured: false))
        }
        switch response.status {
        case 200..<300: return try provider.text(from: response.data)
        case 401, 403: throw StructurerError.notConfigured
        default: throw StructurerError.serverError(response.status)
        }
    }
}
