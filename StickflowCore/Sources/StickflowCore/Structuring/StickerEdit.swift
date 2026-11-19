// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// Voice commands for a sticker (spec 18.22): the model reads the sticker with
/// numbered lines and what was said, and answers with operations on those
/// lines. Dictation without a command is one `add_items`, the old appending.
public struct StickerEdit: Equatable, Sendable {
    public enum LineType: String, Codable, Sendable {
        case task, bullet, heading, text

        var kind: Block.Kind {
            switch self {
            case .task: .todo
            case .bullet: .bullet
            case .heading: .heading2
            case .text: .text
            }
        }
    }

    public enum Operation: Equatable, Sendable {
        /// New lines, the way a dictation is appended (spec 8.3).
        case addItems([NotePlan.Section])
        /// Points under the line `target`.
        case addChildren(target: Int, items: [String])
        case setType(target: Int, type: LineType)
        case check(target: Int)
        case uncheck(target: Int)
        case delete(target: Int)
        /// `position` is where the line ends up, counted from 1 as in the sticker shown.
        case move(target: Int, position: Int)
        case rename(String)
        case editText(target: Int, text: String)
    }

    /// The model could not tell which line was meant: nothing changes.
    public var unsure: Bool
    public var operations: [Operation]

    public init(unsure: Bool = false, operations: [Operation]) {
        self.unsure = unsure
        self.operations = operations
    }

    /// A command touches lines that are there; plain dictation only adds.
    public var isCommand: Bool {
        operations.contains {
            if case .addItems = $0 { return false }
            return true
        }
    }
}

// MARK: - What was said decides

public extension StickerEdit {
    /// Words that point at a line to add under ("добавь в пункт про…", "к задаче…").
    static let childCues = ["в пункт", "к пункт", "под пункт", "подпункт", "в задач", "к задач", "под задач", "в строк", "к строк"]

    /// The answer, held to what was said: points go under a line only when a line
    /// was named. A small model puts a plain thought under a line that looks like
    /// it; such a thought is a new line (spec 18.22).
    func held(to said: String) -> StickerEdit {
        let text = said.lowercased()
        guard !Self.childCues.contains(where: text.contains) else { return self }
        let operations = operations.map { operation -> Operation in
            guard case let .addChildren(_, items) = operation else { return operation }
            return .addItems([NotePlan.Section(items: items.map { NotePlan.Item(text: $0) })])
        }
        return StickerEdit(unsure: unsure, operations: operations)
    }
}

// MARK: - The sticker as the model sees it

public extension StickerEdit {
    /// The sticker as numbered lines, the numbers being what `target` refers to:
    ///
    ///     Заголовок: План
    ///     1. [ ] Доделать экран
    ///     2.     - пустые состояния
    ///     3. [x] Созвон 15:00
    ///     4. ## Кошелёк
    static func numberedLines(title: String, blocks: [Block]) -> String {
        var lines = ["Заголовок: \(title)"]
        for (index, block) in blocks.enumerated() {
            let indent = String(repeating: "    ", count: block.indent)
            let line = switch block.kind {
            case .todo: indent + (block.done ? "[x] " : "[ ] ") + block.text
            case .bullet: indent + "- " + block.text
            case .heading2: "## " + block.text
            case .text: indent + block.text
            }
            lines.append("\(index + 1). \(line)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Applying

public extension StickerEdit {
    struct Result: Equatable, Sendable {
        public var title: String
        public var blocks: [Block]
        /// The lines that are new or changed, to be highlighted (spec 18.22).
        public var changed: Set<UUID>
        public var renamed: Bool
    }

    enum Failure: Error, Equatable, Sendable {
        /// The model was not sure, or named a line that is not there: «Не понял, какой пункт».
        case unclearLine
        /// The answer changes nothing.
        case nothing
    }

    /// Applies the operations to the sticker. Line numbers mean the lines as the
    /// model saw them, before any operation; an unknown number cancels it all.
    func apply(title: String, to blocks: [Block]) throws -> Result {
        if unsure { throw Failure.unclearLine }
        var sheet = Sheet(title: title, lines: blocks, seen: blocks.map(\.id))
        for operation in operations {
            try sheet.perform(operation)
        }
        sheet.changed.formIntersection(sheet.lines.map(\.id))
        guard sheet.lines != blocks || sheet.renamed else { throw Failure.nothing }
        return Result(title: sheet.title, blocks: sheet.lines, changed: sheet.changed, renamed: sheet.renamed)
    }
}

/// The sticker while a command changes it.
private struct Sheet {
    var title: String
    var lines: [Block]
    /// Ids of the lines as the model saw them: line N is `seen[N - 1]`.
    let seen: [UUID]
    var changed = Set<UUID>()
    var renamed = false

    func index(of target: Int) throws -> Int {
        guard target >= 1, target <= seen.count,
              let found = lines.firstIndex(where: { $0.id == seen[target - 1] }) else { throw StickerEdit.Failure.unclearLine }
        return found
    }

    /// The line and the lines nested under it; for a heading, its whole section.
    func subtree(at start: Int) -> Range<Int> {
        let block = lines[start]
        var end = start + 1
        while end < lines.count, lines[end].kind != .heading2, block.kind == .heading2 || lines[end].indent > block.indent {
            end += 1
        }
        return start..<end
    }

    mutating func perform(_ operation: StickerEdit.Operation) throws {
        switch operation {
        case let .addItems(sections):
            let appended = PlanAppender.append(NotePlan(title: "", sections: sections), to: lines)
            for position in appended.added {
                changed.insert(appended.blocks[position].id)
            }
            lines = appended.blocks
        case let .addChildren(target, items):
            try addChildren(items, under: index(of: target))
        case let .setType(target, type):
            let at = try index(of: target)
            let old = lines[at]
            guard old.kind != type.kind else { return }
            lines[at] = Block(id: old.id, kind: type.kind, text: old.text, indent: type == .heading ? 0 : old.indent)
            changed.insert(old.id)
        case let .check(target):
            try mark(index(of: target), done: true)
        case let .uncheck(target):
            try mark(index(of: target), done: false)
        case let .delete(target):
            try lines.removeSubrange(subtree(at: index(of: target)))
        case let .move(target, position):
            try move(index(of: target), to: position)
        case let .rename(newTitle):
            let clean = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean != title else { return }
            title = clean
            renamed = true
        case let .editText(target, text):
            let at = try index(of: target)
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean != lines[at].text else { return }
            lines[at].text = clean
            changed.insert(lines[at].id)
        }
    }

    private mutating func addChildren(_ items: [String], under at: Int) {
        let parent = lines[at]
        let indent = parent.kind == .heading2 ? 0 : min(parent.indent + 1, Block.maxIndent)
        let kind: Block.Kind = parent.kind == .heading2 ? .todo : .bullet
        let known = Set(lines.map { $0.text.lowercased() })
        let fresh = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !known.contains($0.lowercased()) }
            .map { Block(kind: kind, text: $0, indent: indent) }
        lines.insert(contentsOf: fresh, at: subtree(at: at).upperBound)
        changed.formUnion(fresh.map(\.id))
    }

    private mutating func mark(_ at: Int, done: Bool) {
        let old = lines[at]
        guard old.kind != .todo || old.done != done else { return }
        lines[at] = Block(id: old.id, kind: .todo, text: old.text, indent: old.indent, done: done, doneAt: done ? Date() : nil)
        changed.insert(old.id)
    }

    /// `position` counts from 1 among the sticker's lines; the line goes with
    /// its points, and never lands inside another line's points.
    private mutating func move(_ at: Int, to position: Int) {
        let range = subtree(at: at)
        let shift = -lines[at].indent
        let moving = lines[range].map { block in
            // A moved line becomes a line of its own: its nesting starts again from the left.
            block.kind == .heading2 ? block : Block(
                id: block.id, kind: block.kind, text: block.text,
                indent: block.indent + shift, done: block.done, doneAt: block.doneAt
            )
        }
        lines.removeSubrange(range)
        var place = min(max(position - 1, 0), lines.count)
        while place > 0, place < lines.count, lines[place].indent > 0 {
            place += 1
        }
        lines.insert(contentsOf: moving, at: place)
        if let first = moving.first { changed.insert(first.id) }
    }
}

// MARK: - The answer

extension StickerEdit: Decodable {
    private enum Keys: String, CodingKey {
        case unsure, ops
    }

    private enum OperationKeys: String, CodingKey {
        case op, target, items, sections, type, position, text, title
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        unsure = try container.decodeIfPresent(Bool.self, forKey: .unsure) ?? false
        var list = try container.nestedUnkeyedContainer(forKey: .ops)
        var operations: [Operation] = []
        while !list.isAtEnd {
            let item = try list.nestedContainer(keyedBy: OperationKeys.self)
            let name = try item.decode(String.self, forKey: .op)
            func target() throws -> Int { try item.decode(Int.self, forKey: .target) }
            switch name {
            case "add_items":
                try operations.append(.addItems(item.decode([NotePlan.Section].self, forKey: .sections)))
            case "add_children":
                try operations.append(.addChildren(target: target(), items: item.decode([String].self, forKey: .items)))
            case "set_type":
                try operations.append(.setType(target: target(), type: item.decode(LineType.self, forKey: .type)))
            case "check": try operations.append(.check(target: target()))
            case "uncheck": try operations.append(.uncheck(target: target()))
            case "delete": try operations.append(.delete(target: target()))
            case "move":
                try operations.append(.move(target: target(), position: item.decode(Int.self, forKey: .position)))
            case "rename": try operations.append(.rename(item.decode(String.self, forKey: .title)))
            case "edit_text":
                try operations.append(.editText(target: target(), text: item.decode(String.self, forKey: .text)))
            default:
                throw DecodingError.dataCorruptedError(forKey: .op, in: item, debugDescription: "unknown operation \(name)")
            }
        }
        self.operations = operations
    }

    /// Reads a model's answer; text around the JSON is ignored, as with plans.
    public static func parse(_ answer: String) throws -> StickerEdit {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}") else {
            throw StructurerError.invalidAnswer
        }
        do {
            return try JSONDecoder().decode(StickerEdit.self, from: Data(answer[start...end].utf8))
        } catch {
            throw StructurerError.invalidAnswer
        }
    }
}

// MARK: - The request and the prompt

/// What is said into a sticker that is being edited (spec 18.22).
public struct StickerEditRequest: Sendable {
    public var title: String
    public var blocks: [Block]
    public var text: String
    public var now: Date

    public init(title: String, blocks: [Block], text: String, now: Date = Date()) {
        self.title = title
        self.blocks = blocks
        self.text = text
        self.now = now
    }
}

public enum StickerEditPrompt {
    public static let rules = """
    Ты правишь стикер с задачами по голосу. Тебе дают стикер — строки с номерами — и то, что сказал человек.

    Ответ — только JSON: {"unsure": false, "ops": [операции]}. Операции:
    - {"op": "add_items", "sections": [секции, как в разборе диктовки]} — новые пункты;
    - {"op": "add_children", "target": N, "items": ["подпункт"]} — подпункты к строке N, \
    только если сказано, к какой: «добавь в пункт про…», «к пункту…»;
    - {"op": "set_type", "target": N, "type": "task" | "bullet" | "heading" | "text"} — задача с чекбоксом, пункт, подзаголовок, текст;
    - {"op": "check", "target": N} и {"op": "uncheck", "target": N} — отметить задачу сделанной и снять отметку;
    - {"op": "delete", "target": N} — удалить строку вместе с её подпунктами;
    - {"op": "move", "target": N, "position": P} — переставить строку на место P, 1 — самый верх;
    - {"op": "rename", "title": "заголовок"} — переименовать стикер;
    - {"op": "edit_text", "target": N, "text": "новый текст"} — заменить текст строки.

    Правила:
    1. Строку ищи по смыслу: «пункт про калькулятор» — строка, где речь о калькуляторе. «Второй пункт» — строка с номером 2.
    2. Если не ясно, какую строку имели в виду, ничего не меняй: {"unsure": true, "ops": []}.
    3. Если в речи нет команды, это новые мысли: один add_items, даже если они похожи на строку стикера. \
    Задачи — коротко, с глагола, 2–7 слов, без «нужно» и «надо».
    4. Меняй только то, о чём сказано. Не пересказывай и не повторяй строки, которые уже есть.
    5. Несколько команд подряд — несколько операций, по порядку.
    """

    struct Example {
        let said: String
        let answer: String
    }

    static let sticker = """
    Заголовок: Мультизайм
    1. [ ] Доделать калькулятор
    2. [ ] Созвон с разработкой 15:00
    3. - Посмотреть макеты экрана лимита
    4. [ ] Написать пост про запуск
    """

    static let examples = [
        Example(
            said: "добавь в пункт про калькулятор: проверить граничные суммы",
            answer: #"{"unsure": false, "ops": [{"op": "add_children", "target": 1, "items": ["Проверить граничные суммы"]}]}"#
        ),
        Example(
            said: "сделай третий пункт задачей и отметь созвон",
            answer: #"{"unsure": false, "ops": [{"op": "set_type", "target": 3, "type": "task"}, {"op": "check", "target": 2}]}"#
        ),
        Example(
            said: "удали пункт про пост, перенеси макеты наверх и переименуй стикер в Мультизайм, этап два",
            answer: #"{"unsure": false, "ops": [{"op": "delete", "target": 4}, {"op": "move", "target": 3, "position": 1}, "#
                + #"{"op": "rename", "title": "Мультизайм, этап 2"}]}"#
        ),
        Example(
            said: "ещё надо согласовать тексты с юристами",
            answer: #"{"unsure": false, "ops": [{"op": "add_items", "sections": [{"heading": null, "items": ["#
                + #"{"text": "Согласовать тексты с юристами", "task": true, "time": null, "children": []}]}]}]}"#
        ),
        Example(
            said: "отметь тот пункт",
            answer: #"{"unsure": true, "ops": []}"#
        ),
    ]

    public static func messages(for request: StickerEditRequest) -> [ChatMessage] {
        var messages = [ChatMessage(role: .system, content: rules)]
        for example in examples {
            messages.append(ChatMessage(role: .user, content: "Стикер:\n\(sticker)\n\nСказано: \(example.said)"))
            messages.append(ChatMessage(role: .assistant, content: example.answer))
        }
        let shown = StickerEdit.numberedLines(title: request.title, blocks: request.blocks)
        messages.append(ChatMessage(role: .user, content: "Стикер:\n\(shown)\n\nСказано: \(request.text)"))
        return messages
    }

    /// The answer's shape for the built-in model: operations only, the new
    /// lines of `add_items` in the shape of a plan (`PlanGrammar`).
    public static let grammar: String = {
        let root = #"""
        root ::= "{" ws "\"unsure\"" ws ":" ws ( "true" | "false" ) ws "," ws "\"ops\"" ws ":" ws "[" ws ops? ws "]" ws "}"
        ops ::= op ( ws "," ws op ){0,7}
        op ::= "{" ws "\"op\"" ws ":" ws ( additems | addchildren | settype | mark | move | rename | edittext ) ws "}"
        additems ::= "\"add_items\"" ws "," ws "\"sections\"" ws ":" ws "[" ws sections? ws "]"
        addchildren ::= "\"add_children\"" ws "," ws target ws "," ws "\"items\"" ws ":" ws "[" ws children? ws "]"
        settype ::= "\"set_type\"" ws "," ws target ws "," ws "\"type\"" ws ":" ws linetype
        linetype ::= "\"task\"" | "\"bullet\"" | "\"heading\"" | "\"text\""
        mark ::= ( "\"check\"" | "\"uncheck\"" | "\"delete\"" ) ws "," ws target
        move ::= "\"move\"" ws "," ws target ws "," ws "\"position\"" ws ":" ws number
        rename ::= "\"rename\"" ws "," ws "\"title\"" ws ":" ws title
        edittext ::= "\"edit_text\"" ws "," ws target ws "," ws "\"text\"" ws ":" ws text
        target ::= "\"target\"" ws ":" ws number
        number ::= [1-9] [0-9]?
        """#
        let planRules = PlanGrammar.gbnf
            .split(separator: "\n")
            .filter { !$0.hasPrefix("root ::=") }
            .joined(separator: "\n")
        return root + "\n" + planRules
    }()
}

// MARK: - Providers

public extension Structurer {
    /// Only a model understands commands; the rules only append (spec 18.22).
    var editsStickers: Bool { false }

    func edit(_: StickerEditRequest) async throws -> StickerEdit {
        throw StructurerError.invalidAnswer
    }
}
