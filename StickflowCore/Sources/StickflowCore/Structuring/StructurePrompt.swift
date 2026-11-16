// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// One turn of a conversation with a language model.
public struct ChatMessage: Equatable, Sendable {
    public enum Role: String, Sendable {
        case system, user, assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// What a language model is told when it is asked to take text apart (spec 8.3–8.5):
/// the compression rules, the shape of the answer and three examples.
public enum StructurePrompt {
    /// The compression rules of spec 8.4; the settings may replace them.
    public static let defaultRules = """
    Ты превращаешь надиктованный текст в короткий план задач. Стиль — «Пиши, сокращай» и Илья Бирман.
    — Выкинь слова-паразиты и вводные: короче, типа, условно, ну, вот, как бы, в общем, наверное, знаешь.
    — Один пункт — одно действие. Начинай с глагола в инфинитиве: «Доделать», «Написать», «Созвониться».
    — Имена, названия, время и числа не меняй. Время пиши как 15:00 в поле time.
    — Ничего не додумывай и не добавляй от себя. Нет действия — не создавай пункт.
    — Группируй по проектам или темам, только если они названы. Нет темы — секция с heading: null.
    — Детали задачи — children по 1–4 слова.
    — «Если успею», «по возможности», «желательно» — отдельная секция «Если успею» в конце.
    — Заголовок — 1–3 слова. Неясно — «План на сегодня».
    — Отвечай на языке ввода.
    """

    /// The JSON schema of the answer (spec 8.3).
    public static let schema = """
    {"type":"object","required":["title","sections"],"additionalProperties":false,"properties":{\
    "title":{"type":"string","maxLength":40},\
    "sections":{"type":"array","items":{"type":"object","required":["heading","items"],"additionalProperties":false,"properties":{\
    "heading":{"type":["string","null"],"maxLength":32},\
    "items":{"type":"array","items":{"type":"object","required":["text","task","time","children"],\
    "additionalProperties":false,"properties":{\
    "text":{"type":"string","maxLength":80},\
    "task":{"type":"boolean"},\
    "time":{"type":["string","null"],"pattern":"^\\\\d{2}:\\\\d{2}$"},\
    "children":{"type":"array","items":{"type":"string","maxLength":48}}}}}}}}}}
    """

    static let format = """
    Ответь одним объектом JSON и больше ничем, без пояснений и без ```. Форма: \
    {"title": строка, "sections": [{"heading": строка или null, "items": [{"text": строка, "task": true или false, \
    "time": "ЧЧ:ММ" или null, "children": [строки]}]}]}.
    """

    static let reminder = "Ответ не разобрался как JSON. Пришли только объект JSON в той же форме, без единого слова вокруг."

    /// The examples of spec 8.5: what was said and the answer wanted.
    static let examples: [(said: String, answer: String)] = [
        (
            "Короче, сначала надо доделать экран кошелька, там типа пустые состояния и ошибки, потом созвон с разработкой в три, "
                + "и если успею, условно, пост в телегу написать",
            """
            {"title":"План на день","sections":[\
            {"heading":"Кошелёк","items":[{"text":"Доделать экран","task":true,"time":null,"children":["пустые состояния","ошибки"]}]},\
            {"heading":"Созвоны","items":[{"text":"Созвониться с разработкой","task":true,"time":"15:00","children":[]}]},\
            {"heading":"Если успею","items":[{"text":"Написать пост в телегу","task":true,"time":null,"children":[]}]}]}
            """
        ),
        (
            "Ну вот, мне нужно сегодня проверить макеты онбординга. Потом в 11 созвон с Петей, и ещё отправить счёт бухгалтерии, это важно",
            """
            {"title":"План на сегодня","sections":[{"heading":null,"items":[\
            {"text":"Проверить макеты онбординга","task":true,"time":null,"children":[]},\
            {"text":"Созвониться с Петей","task":true,"time":"11:00","children":[]},\
            {"text":"Отправить счёт бухгалтерии","task":true,"time":null,"children":[]}]}]}
            """
        ),
        (
            "В общем по лендингу Маши: поправить шапку, заменить фотки в кейсах и проверить мобилку. А, и купить молоко",
            """
            {"title":"Лендинг Маши","sections":[{"heading":"Лендинг Маши","items":[\
            {"text":"Поправить шапку","task":true,"time":null,"children":[]},\
            {"text":"Заменить фото в кейсах","task":true,"time":null,"children":[]},\
            {"text":"Проверить мобильную версию","task":true,"time":null,"children":[]}]},\
            {"heading":"Личное","items":[{"text":"Купить молоко","task":true,"time":null,"children":[]}]}]}
            """
        ),
    ]

    /// The whole conversation for a request: the rules, the examples, the text.
    public static func messages(for request: StructureRequest) -> [ChatMessage] {
        let rules = request.rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultRules : request.rules
        var messages = [ChatMessage(role: .system, content: rules + "\n\n" + format)]
        for example in examples {
            messages.append(ChatMessage(role: .user, content: example.said))
            messages.append(ChatMessage(role: .assistant, content: example.answer))
        }
        switch request.mode {
        case .new:
            messages.append(ChatMessage(role: .user, content: request.text))
        case let .append(existing):
            // Spec 8.3: the note as it is goes along, and nothing in it is to be repeated.
            let note = existing.previewLines().joined(separator: "\n")
            messages.append(ChatMessage(
                role: .user,
                content: "Вот записка, которая уже есть:\n\(note)\n\nДопиши в неё только новое, существующие пункты не повторяй. "
                    + "Секцию с тем же названием назови так же. Новое:\n\(request.text)"
            ))
        }
        return messages
    }

    /// The conversation after an answer that could not be read: one more try (spec 8.3).
    public static func retry(_ messages: [ChatMessage], after answer: String) -> [ChatMessage] {
        messages + [ChatMessage(role: .assistant, content: answer), ChatMessage(role: .user, content: reminder)]
    }
}

/// Reads a model's answer as a plan (spec 8.3).
public enum PlanParser {
    /// - Throws: `StructurerError.invalidAnswer` when there is no plan in the answer.
    public static func parse(_ answer: String) throws -> NotePlan {
        // Models like to wrap JSON in a code fence or a sentence: take the outermost object.
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end else {
            throw StructurerError.invalidAnswer
        }
        let json = Data(answer[start...end].utf8)
        guard let plan = try? JSONDecoder().decode(NotePlan.self, from: json).normalized(), !plan.isEmpty else {
            throw StructurerError.invalidAnswer
        }
        return plan
    }
}
