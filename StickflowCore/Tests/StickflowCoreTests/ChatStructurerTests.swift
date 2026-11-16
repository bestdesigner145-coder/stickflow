// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

@testable import StickflowCore
import XCTest

/// Answers from a script and remembers what it was asked.
private actor ScriptedNetwork: Network {
    private var answers: [(String, Int)]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [(String, Int)]) {
        self.answers = answers
    }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        requests.append(request)
        guard !answers.isEmpty else { throw URLError(.badServerResponse) }
        let next = answers.removeFirst()
        return (Data(next.0.utf8), next.1)
    }
}

final class ChatStructurerTests: XCTestCase {
    private let ollama = ChatProvider.ollama(host: URL(string: "http://localhost:11434")!, model: "qwen3:4b")
    private let openAI = ChatProvider.openAICompatible(baseURL: URL(string: "https://llm.example.com")!, model: "small")
    private let claude = ChatProvider.claude(model: ChatProvider.claudeDefaultModel)
    private let planJSON = #"{"title":"План","sections":[{"heading":null,"items":["#
        + #"{"text":"Купить молоко","task":true,"time":null,"children":[]}]}]}"#

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func ollamaAnswer(_ content: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["message": ["role": "assistant", "content": content]])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    // MARK: The prompt

    func testPromptHasTheRulesTheExamplesAndTheText() throws {
        let messages = StructurePrompt.messages(for: StructureRequest(text: "Купить молоко"))
        XCTAssertEqual(messages.count, 2 + 2 * StructurePrompt.examples.count)
        XCTAssertEqual(Array(messages.map(\.role).prefix(3)), [.system, .user, .assistant])
        XCTAssertEqual(messages.last?.role, .user)
        // Spec 18.2: grouping by meaning, no repeats, no greetings.
        XCTAssertTrue(messages[0].content.contains("Группируй по смыслу"))
        XCTAssertTrue(messages[0].content.contains("не новый пункт"))
        XCTAssertTrue(messages[0].content.contains("не задачи"))
        XCTAssertTrue(messages[0].content.contains("Один пункт — одно действие"))
        XCTAssertTrue(messages[0].content.contains("JSON"))
        XCTAssertEqual(messages.last?.content, "Купить молоко")
        // Every example answer is a plan the parser reads.
        for answer in messages.filter({ $0.role == .assistant }) {
            XCTAssertFalse(try PlanParser.parse(answer.content).isEmpty)
        }
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(StructurePrompt.schema.utf8)))

        let own = StructurePrompt.messages(for: StructureRequest(text: "x", rules: "Пиши коротко."))
        XCTAssertTrue(own[0].content.hasPrefix("Пиши коротко."))
        XCTAssertFalse(own[0].content.contains("Илья Бирман"))
    }

    func testPromptForAddingCarriesTheNote() {
        let note = NotePlan(title: "План", sections: [NotePlan.Section(heading: "Дом", items: [NotePlan.Item(text: "Помыть окна")])])
        let messages = StructurePrompt.messages(for: StructureRequest(text: "Купить молоко", mode: .append(existing: note)))
        let last = messages.last?.content ?? ""
        XCTAssertTrue(last.contains("☐ Помыть окна"))
        XCTAssertTrue(last.contains("ДОМ"))
        XCTAssertTrue(last.hasSuffix("Купить молоко"))
        let again = StructurePrompt.retry(messages, after: "ой")
        XCTAssertEqual(again.count, messages.count + 2)
        XCTAssertEqual(again[messages.count], ChatMessage(role: .assistant, content: "ой"))
        XCTAssertEqual(again.last?.role, .user)
    }

    // MARK: The answer

    func testParserFindsThePlanInAChattyAnswer() throws {
        let plan = try PlanParser.parse("Вот план:\n```json\n" + planJSON + "\n```\nГотово!")
        XCTAssertEqual(plan, NotePlan(title: "План", sections: [NotePlan.Section(items: [NotePlan.Item(text: "Купить молоко")])]))
        let blank = #"{"title":"x","sections":[{"heading":null,"items":[{"text":" ","task":true}]}]}"#
        for bad in ["", "нет", "{}", "} {"] {
            XCTAssertThrowsError(try PlanParser.parse(bad), bad) { error in
                XCTAssertEqual(error as? StructurerError, .invalidAnswer)
            }
        }
        // A plan that is there and holds nothing: the model found nothing to do.
        for empty in [#"{"title":"x","sections":[]}"#, blank] {
            XCTAssertThrowsError(try PlanParser.parse(empty), empty) { error in
                XCTAssertEqual(error as? StructurerError, .nothingToDo)
            }
        }
    }

    // MARK: The providers

    func testOllamaRequestAndAnswer() throws {
        let messages = [ChatMessage(role: .system, content: "s"), ChatMessage(role: .user, content: "u")]
        let request = try ollama.request(messages: messages, apiKey: nil)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/api/chat")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let sent = try body(request)
        XCTAssertEqual(sent["model"] as? String, "qwen3:4b")
        XCTAssertEqual(sent["stream"] as? Bool, false)
        XCTAssertEqual(sent["think"] as? Bool, false)
        XCTAssertEqual((sent["options"] as? [String: Any])?["temperature"] as? Double, 0.2)
        XCTAssertEqual((sent["options"] as? [String: Any])?["num_ctx"] as? Int, 8192)
        XCTAssertEqual((sent["messages"] as? [[String: String]])?.map { $0["role"] ?? "" }, ["system", "user"])
        XCTAssertEqual((sent["format"] as? [String: Any])?["type"] as? String, "object")
        XCTAssertNil(try body(ollama.request(messages: messages, apiKey: nil, structured: false))["format"])

        XCTAssertEqual(try ollama.text(from: Data(ollamaAnswer("привет").utf8)), "привет")
        XCTAssertThrowsError(try ollama.text(from: Data("{}".utf8)))
        XCTAssertThrowsError(try ollama.text(from: Data("не json".utf8)))
        XCTAssertTrue(ollama.isLocal)
        XCTAssertEqual(ollama.id, "ollama")
        XCTAssertEqual(ollama.displayName, "Ollama (qwen3:4b)")
        XCTAssertFalse(try ChatProvider.ollama(host: XCTUnwrap(URL(string: "http://192.168.1.5:11434")), model: "m").isLocal)
    }

    func testOpenAICompatibleRequestAndAnswer() throws {
        let messages = [ChatMessage(role: .user, content: "u")]
        let request = try openAI.request(messages: messages, apiKey: "sk-test")
        XCTAssertEqual(request.url?.absoluteString, "https://llm.example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let sent = try body(request)
        XCTAssertEqual(sent["temperature"] as? Double, 0.2)
        let format = try XCTUnwrap(sent["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual((format["json_schema"] as? [String: Any])?["name"] as? String, "note_plan")
        let plain = try openAI.request(messages: messages, apiKey: nil, structured: false)
        XCTAssertNil(try body(plain)["response_format"])
        XCTAssertNil(plain.value(forHTTPHeaderField: "Authorization"))

        let answer = #"{"choices":[{"message":{"role":"assistant","content":"ок"}}]}"#
        XCTAssertEqual(try openAI.text(from: Data(answer.utf8)), "ок")
        XCTAssertThrowsError(try openAI.text(from: Data(#"{"choices":[]}"#.utf8)))
        XCTAssertFalse(openAI.isLocal)
        XCTAssertTrue(try ChatProvider.openAICompatible(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:1234")), model: "m").isLocal)
        XCTAssertEqual(openAI.id, "openai-compatible")
        XCTAssertEqual(openAI.displayName, "llm.example.com (small)")
    }

    func testClaudeRequestAndAnswer() throws {
        let messages = [
            ChatMessage(role: .system, content: "правила"),
            ChatMessage(role: .user, content: "пример"),
            ChatMessage(role: .assistant, content: "{}"),
            ChatMessage(role: .user, content: "текст"),
        ]
        let request = try claude.request(messages: messages, apiKey: "key")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let sent = try body(request)
        XCTAssertEqual(sent["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(sent["system"] as? String, "правила")
        XCTAssertEqual(sent["max_tokens"] as? Int, 2048)
        XCTAssertEqual((sent["messages"] as? [[String: String]])?.map { $0["role"] ?? "" }, ["user", "assistant", "user"])
        XCTAssertThrowsError(try claude.request(messages: messages, apiKey: nil)) { error in
            XCTAssertEqual(error as? StructurerError, .notConfigured)
        }
        XCTAssertThrowsError(try claude.request(messages: messages, apiKey: ""))

        let answer = #"{"content":[{"type":"thinking","thinking":"…"},{"type":"text","text":"раз"},{"type":"text","text":"два"}]}"#
        XCTAssertEqual(try claude.text(from: Data(answer.utf8)), "раздва")
        XCTAssertThrowsError(try claude.text(from: Data(#"{"content":[{"type":"thinking","thinking":"…"}]}"#.utf8)))
        XCTAssertFalse(claude.isLocal)
        XCTAssertEqual(claude.id, "claude")
        XCTAssertEqual(claude.displayName, "Claude (claude-haiku-5-5)")
    }

    // MARK: The structurer

    func testStructurerReturnsThePlan() async throws {
        let network = try ScriptedNetwork([(ollamaAnswer(planJSON), 200)])
        let structurer = ChatStructurer(provider: ollama, network: network)
        let plan = try await structurer.structure(StructureRequest(text: "Купить молоко"))
        XCTAssertEqual(plan.items.map(\.text), ["Купить молоко"])
        let requests = await network.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(structurer.id, "ollama")
        XCTAssertTrue(structurer.isLocal)
        XCTAssertFalse(structurer.displayName.isEmpty)
        let health = await structurer.health()
        XCTAssertEqual(health, .ready)
    }

    func testAnAnswerThatCannotBeReadIsAskedForOnceMore() async throws {
        let network = try ScriptedNetwork([(ollamaAnswer("Сейчас подумаю"), 200), (ollamaAnswer(planJSON), 200)])
        let plan = try await ChatStructurer(provider: ollama, network: network).structure(StructureRequest(text: "Купить молоко"))
        XCTAssertEqual(plan.title, "План")
        let requests = await network.requests
        XCTAssertEqual(requests.count, 2)
        let turns = try XCTUnwrap(body(requests[1])["messages"] as? [[String: String]])
        let asked = 2 + 2 * StructurePrompt.examples.count
        XCTAssertEqual(turns.count, asked + 2, "the first answer and the reminder are added")
        XCTAssertEqual(turns[asked]["content"], "Сейчас подумаю")

        let stubborn = try ScriptedNetwork([(ollamaAnswer("нет"), 200), (ollamaAnswer("и снова нет"), 200)])
        do {
            _ = try await ChatStructurer(provider: ollama, network: stubborn).structure(StructureRequest(text: "x"))
            XCTFail("two unreadable answers are a failure")
        } catch {
            XCTAssertEqual(error as? StructurerError, .invalidAnswer)
        }
    }

    func testRepeatsAndGreetingsAreTakenOutOfAnAnswer() async throws {
        let answer = #"{"title":"Карта","sections":[{"heading":null,"items":[{"text":"Привет","task":true},"#
            + #"{"text":"Внести правки в карту","task":true},{"text":"Внести правки в виртуальную карту","task":true}]}]}"#
        let network = try ScriptedNetwork([(ollamaAnswer(answer), 200), (ollamaAnswer(answer), 200)])
        let structurer = ChatStructurer(provider: ollama, network: network)
        let plan = try await structurer.structure(StructureRequest(text: "x"))
        XCTAssertEqual(plan.items.map(\.text), ["Внести правки в виртуальную карту"])
        let draft = try await structurer.draft(StructureRequest(text: "x"))
        XCTAssertEqual(draft.items.count, 3, "the draft is the answer as it came")
    }

    func testNothingToDoIsNotAskedTwice() async throws {
        let empty = #"{"title":"План на сегодня","sections":[]}"#
        let greeting = #"{"title":"План","sections":[{"heading":null,"items":[{"text":"Привет","task":true}]}]}"#
        for answer in [empty, greeting] {
            let network = try ScriptedNetwork([(ollamaAnswer(answer), 200)])
            do {
                _ = try await ChatStructurer(provider: ollama, network: network).structure(StructureRequest(text: "Привет"))
                XCTFail("there is nothing to do in a greeting")
            } catch {
                XCTAssertEqual(error as? StructurerError, .nothingToDo)
            }
            let requests = await network.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testAServerWithoutSchemasIsAskedPlainly() async throws {
        let network = try ScriptedNetwork([("{}", 400), (ollamaAnswer(planJSON), 200)])
        _ = try await ChatStructurer(provider: ollama, network: network).structure(StructureRequest(text: "x"))
        let requests = await network.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotNil(try body(requests[0])["format"])
        XCTAssertNil(try body(requests[1])["format"])
    }

    func testFailuresOfTheService() async {
        func failure(_ answers: [(String, Int)], provider: ChatProvider, key: String? = "key") async -> StructurerError? {
            let structurer = ChatStructurer(provider: provider, network: ScriptedNetwork(answers), apiKey: { key })
            do {
                _ = try await structurer.structure(StructureRequest(text: "x"))
                return nil
            } catch {
                return error as? StructurerError
            }
        }
        var result = await failure([("", 401)], provider: openAI)
        XCTAssertEqual(result, .notConfigured)
        result = await failure([("", 503)], provider: ollama)
        XCTAssertEqual(result, .serverError(503))
        // Claude is not asked twice about a request it refused.
        result = await failure([("", 400), ("", 200)], provider: claude)
        XCTAssertEqual(result, .serverError(400))
        result = await failure([], provider: claude, key: nil)
        XCTAssertEqual(result, .notConfigured)
        let keyless = ChatStructurer(provider: claude, network: ScriptedNetwork([]))
        let health = await keyless.health()
        XCTAssertEqual(health, .unavailable("no API key"))
    }
}
