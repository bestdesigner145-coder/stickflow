// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// The answer's shape (spec 8.3) as a GBNF grammar for the built-in model
/// (spec 18.10): the model cannot write anything that is not a plan. Strings
/// are bounded, so that a model that loops on a word stops at the limit, and
/// so is whitespace, which small models like to repeat.
public enum PlanGrammar {
    public static let gbnf = #"""
    root ::= "{" ws "\"title\"" ws ":" ws title ws "," ws "\"sections\"" ws ":" ws "[" ws sections? ws "]" ws "}"
    sections ::= section ( ws "," ws section ){0,7}
    section ::= "{" ws "\"heading\"" ws ":" ws ( heading | "null" ) ws "," ws "\"items\"" ws ":" ws "[" ws items? ws "]" ws "}"
    items ::= item ( ws "," ws item ){0,14}
    item ::= "{" ws "\"text\"" ws ":" ws text ws "," ws task ws "," ws time ws "," ws details ws "}"
    task ::= "\"task\"" ws ":" ws ( "true" | "false" )
    time ::= "\"time\"" ws ":" ws ( clock | "null" )
    details ::= "\"children\"" ws ":" ws "[" ws children? ws "]"
    children ::= child ( ws "," ws child ){0,5}
    title ::= "\"" char{1,40} "\""
    heading ::= "\"" char{1,32} "\""
    text ::= "\"" char{1,80} "\""
    child ::= "\"" char{1,48} "\""
    clock ::= "\"" [0-2] [0-9] ":" [0-5] [0-9] "\""
    char ::= [^"\\\x00-\x1F] | "\\" ( ["\\/bfnrt] | "u" [0-9a-fA-F]{4} )
    ws ::= [ \t\n]{0,8}
    """#
}

/// How a conversation is put into one prompt for a model that runs inside the
/// app. The families are those of the models the app may download.
public enum PromptFormat: Equatable, Sendable {
    /// `<|im_start|>role … <|im_end|>`: Qwen and its fine-tunes. `thinkingOff`
    /// opens the answer with an empty `<think>` block, which is how a Qwen3
    /// model is told not to reason before it answers (spec 18.10).
    case chatML(thinkingOff: Bool)
    /// `<start_of_turn>user … <end_of_turn>`: Gemma, which has no system turn.
    case gemma

    /// Works the family out from the chat template inside the model file.
    public static func detect(template: String?) -> PromptFormat? {
        guard let template else { return nil }
        if template.contains("<start_of_turn>") { return .gemma }
        if template.contains("<|im_start|>") { return .chatML(thinkingOff: template.contains("<think>")) }
        return nil
    }

    /// The whole prompt, ending where the model's answer begins.
    public func render(_ messages: [ChatMessage]) -> String {
        switch self {
        case let .chatML(thinkingOff):
            var text = ""
            for message in messages {
                text += "<|im_start|>\(message.role.rawValue)\n\(message.content)<|im_end|>\n"
            }
            text += "<|im_start|>assistant\n"
            if thinkingOff { text += "<think>\n\n</think>\n\n" }
            return text
        case .gemma:
            var text = "<bos>"
            var pendingSystem = ""
            for message in messages {
                switch message.role {
                case .system:
                    pendingSystem += message.content + "\n\n"
                case .user:
                    text += "<start_of_turn>user\n\(pendingSystem)\(message.content)<end_of_turn>\n"
                    pendingSystem = ""
                case .assistant:
                    text += "<start_of_turn>model\n\(message.content)<end_of_turn>\n"
                }
            }
            return text + "<start_of_turn>model\n"
        }
    }
}

public extension NotePlan {
    /// The plan under a title no sticker on screen has (spec 18.7). A model is
    /// asked for another wording first; whatever still collides gets the time.
    func titled(apartFrom taken: [String], at now: Date, calendar: Calendar = .current) -> NotePlan {
        let used = Set(taken.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guard used.contains(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else { return self }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        var plan = self
        let base = String(title.prefix(Limit.title - clock.count - 2))
        plan.title = "\(base), \(clock)"
        var number = 2
        while used.contains(plan.title.lowercased()) {
            plan.title = "\(base), \(clock) (\(number))"
            number += 1
        }
        return plan
    }
}
