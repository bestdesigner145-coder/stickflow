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
    /// Tokens of context asked of Ollama.
    static let ollamaContext = 8192

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

    /// Claude and services on the internet take no request without a key;
    /// Ollama and a server on this Mac need none.
    public var needsKey: Bool {
        switch self {
        case .ollama: false
        case let .openAICompatible(baseURL, _): !Self.isLoopback(baseURL)
        case .claude: true
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
            // "think": models that reason aloud first (qwen3) would take many times longer.
            // "num_ctx": the rules and the examples alone do not fit a server's default window.
            let options: [String: Any] = ["temperature": 0.2, "num_ctx": Self.ollamaContext]
            body = ["model": model, "messages": turns, "stream": false, "think": false, "options": options]
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
                throw StructurerError.missingKey
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
        let plan = try await draft(request).cleaned()
        guard !plan.isEmpty else { throw StructurerError.nothingToDo }
        return plan
    }

    /// The model's plan as it came, before repeats and greetings are taken out
    /// (spec 18.2). The report counts the repeats in it.
    public func draft(_ request: StructureRequest) async throws -> NotePlan {
        let messages = StructurePrompt.messages(for: request)
        let answer = try await ask(messages)
        do {
            return try PlanParser.parse(answer)
        } catch StructurerError.invalidAnswer {
            return try await PlanParser.parse(ask(StructurePrompt.retry(messages, after: answer)))
        }
    }

    public var editsStickers: Bool { true }

    /// Voice commands for a sticker (spec 18.22). The plan's schema does not fit
    /// operations, so the answer's format is named by the prompt alone.
    public func edit(_ request: StickerEditRequest) async throws -> StickerEdit {
        let messages = StickerEditPrompt.messages(for: request)
        return try await StickerEdit.parse(ask(messages, structured: false))
    }

    private func ask(_ messages: [ChatMessage], structured: Bool = true) async throws -> String {
        let key = apiKey()
        // A service on the internet takes no request without a key (spec 18.10 C2).
        if provider.needsKey, (key ?? "").isEmpty { throw StructurerError.missingKey }
        var response = try await send(provider.request(messages: messages, apiKey: key, structured: structured))
        if structured, response.status == 400 || response.status == 422, provider.id != "claude" {
            // A server that does not know schema-bound answers: ask plainly, the prompt names the format.
            response = try await send(provider.request(messages: messages, apiKey: key, structured: false))
        }
        if (200..<300).contains(response.status) { return try provider.text(from: response.data) }
        throw Self.failure(status: response.status, body: String(bytes: response.data, encoding: .utf8) ?? "")
    }

    private func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        do {
            return try await network.send(request)
        } catch let error as URLError {
            throw Self.failure(error)
        }
    }

    /// What a failed answer means to the user (spec 18.10 C2).
    public static func failure(status: Int, body: String) -> StructurerError {
        let text = body.lowercased()
        switch status {
        case 401, 403: return .rejectedKey
        case 402: return .noCredit
        case 400 where text.contains("credit balance"): return .noCredit
        case 429 where text.contains("insufficient_quota") || text.contains("balance"): return .noCredit
        case 404 where text.contains("model"): return .noModel
        default: return .unavailable(status)
        }
    }

    /// No internet, or a service that cannot be reached.
    public static func failure(_ error: URLError) -> StructurerError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: .offline
        case .timedOut: .timedOut
        default: .unavailable(0)
        }
    }
}
