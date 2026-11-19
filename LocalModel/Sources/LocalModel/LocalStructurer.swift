// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
import StickflowCore

/// Takes dictation apart with the model inside the app (spec 18.10): nothing
/// leaves the Mac, nothing has to be installed. The answer is held to the
/// plan's grammar, so there is no "could not read the answer".
public struct LocalStructurer: Structurer {
    public static let identifier = "local"

    public let id = LocalStructurer.identifier
    public let displayName: String
    public let isLocal = true
    public let runner: LlamaRunner

    public init(runner: LlamaRunner, displayName: String) {
        self.runner = runner
        self.displayName = displayName
    }

    public func health() async -> StructurerHealth {
        FileManager.default.fileExists(atPath: runner.file.path) ? .ready : .unavailable("the model is not downloaded")
    }

    public func structure(_ request: StructureRequest) async throws -> NotePlan {
        let plan = try await draft(request).plan.cleaned()
        guard !plan.isEmpty else { throw StructurerError.nothingToDo }
        return plan.titled(apartFrom: request.takenTitles, at: request.now)
    }

    public var editsStickers: Bool { true }

    /// Voice commands for a sticker (spec 18.22), held to the grammar of operations.
    public func edit(_ request: StickerEditRequest) async throws -> StickerEdit {
        let format = try await runner.promptFormat() ?? .chatML(thinkingOff: true)
        let prompt = format.render(StickerEditPrompt.messages(for: request))
        let answer = try await runner.generate(prompt: prompt, grammar: StickerEditPrompt.grammar)
        return try StickerEdit.parse(answer.text).held(to: request.text)
    }

    /// Loads the model and reads the rules and examples, which every request
    /// begins with, while the user is still speaking.
    public func prime() async {
        guard let format = try? await runner.promptFormat() ?? .chatML(thinkingOff: true) else { return }
        let prefix = format.prefix(StructurePrompt.messages(for: StructureRequest(text: "")))
        try? await runner.prefill(prompt: prefix)
    }

    /// The model's plan as it came, before repeats and greetings are taken out,
    /// with what it cost. The report counts the repeats.
    public func draft(_ request: StructureRequest) async throws -> (plan: NotePlan, timings: LlamaTimings) {
        let format = try await runner.promptFormat() ?? .chatML(thinkingOff: true)
        let prompt = format.render(StructurePrompt.messages(for: request))
        let answer = try await runner.generate(prompt: prompt, grammar: PlanGrammar.gbnf)
        return try (PlanParser.parse(answer.text), answer.timings)
    }
}
