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

/// What a language model is told when it is asked to take text apart (spec 18.9,
/// which replaces 8.4): the rules, the shape of the answer and five examples.
public enum StructurePrompt {
    /// The rules of spec 18.9 (B1 of the iteration of 17.11.2026), word for word;
    /// the settings may replace them.
    public static let defaultRules = """
    Ты превращаешь сбивчивую диктовку в короткий план задач.
    1. Сначала пойми, к какому результату идёт человек. Не пересказывай его фразы — сформулируй задачи заново своими словами.
    2. Задача — конкретное действие с понятным результатом, 2–7 слов, начинается с глагола в инфинитиве: \
    «Изучить методы исследований на сайте UX Feedback».
    3. Объяснения, контекст и причины («это такой сервис…», «грубо говоря», «исходя из того, что…») — не задачи и не подпункты. \
    Используй их только чтобы точнее назвать задачу или заголовок.
    4. Ставь задачи в порядке, в котором их логично делать, а не в порядке, в котором они сказаны.
    5. Всё, что ведёт к одному результату, — одна задача. Повтор или уточнение — не новый пункт.
    6. Подпункты — только если человек сам перечислил части задачи.
    7. Заголовок — тема стикера, 1–3 слова. «План на сегодня» — только если темы нет.
    8. Время без «утра» или «вечера» («в три») не угадывай — пиши как сказано.
    9. Ничего не придумывай. Имена, названия сервисов, числа сохраняй как сказаны.
    10. Приветствия, слова-паразиты и фразы про саму диктовку («чтобы меня было слышно», «такой план») — выбрасывай.
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

    /// The shape of the answer, and how sections are made (spec 8.3, 18.2).
    static let format = """
    Ответь одним объектом JSON и больше ничем, без пояснений и без ```. Форма: \
    {"title": строка, "sections": [{"heading": строка или null, "items": [{"text": строка, "task": true или false, \
    "time": "ЧЧ:ММ" или null, "children": [строки]}]}]}.
    Секции — темы. Всё про один продукт, проект, экран, человека или дом — в одной секции с названием темы, \
    даже если слова «проект» не было. Тема одна — секция одна, heading: null, а тема — в title. \
    «Если успею», «по возможности» — отдельная секция «Если успею» в конце.
    time — только если время названо с часами и минутами или с «утра», «дня», «вечера»; иначе null, а время остаётся в тексте пункта.
    children — только части задачи, которые человек сам перечислил; нет — пустой список. Сам пункт в children не повторяй.
    Нет ни одного действия — sections пустой.
    """

    static let reminder = "Ответ не разобрался как JSON. Пришли только объект JSON в той же форме, без единого слова вокруг."

    /// The phrase of spec 18.9, B3.1: a description of a service is not a task.
    public static let uxFeedbackPhrase = "Привет. Сегодня мне нужно сделать написать вопросы для UX-фидбека по нашему приложению. "
        + "Грубо говоря, у нас будет проводиться исследование в приложении через сервис UX Feedback. Вот. "
        + "И мне нужно выписать предложения, гипотезы, которые я бы хотел протестировать и через какой метод исследования. "
        + "Исходя из того, что у них там на сайте написано."

    /// The phrase of spec 18.9, B3.2, as restored from the sticker of the review of 16.11.2026.
    public static let virtualCardPhrase = "Привет. Так, внести правки в виртуальную карту, чтобы меня слышно вообще. "
        + "Внести правки в виртуальную карту: заменить иконку на главном экране и проверить лимиты."

    /// The examples of spec 8.5 with the time of 18.9, and the two regressions of 18.9:
    /// what was said and the answer wanted.
    public static let examples: [(said: String, answer: String)] = [
        (
            "Короче, сначала надо доделать экран кошелька, там типа пустые состояния и ошибки, потом созвон с разработкой в три, "
                + "и если успею, условно, пост в телегу написать",
            """
            {"title":"План на сегодня","sections":[\
            {"heading":"Кошелёк","items":[{"text":"Доделать экран","task":true,"time":null,"children":["пустые состояния","ошибки"]}]},\
            {"heading":"Созвоны","items":[{"text":"Созвониться с разработкой в 3","task":true,"time":null,"children":[]}]},\
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
        (
            uxFeedbackPhrase,
            """
            {"title":"UX Feedback","sections":[{"heading":null,"items":[\
            {"text":"Изучить методы исследований на сайте UX Feedback","task":true,"time":null,"children":[]},\
            {"text":"Выписать гипотезы и метод проверки для каждой","task":true,"time":null,"children":[]},\
            {"text":"Написать вопросы для UX-фидбэка","task":true,"time":null,"children":[]}]}]}
            """
        ),
        (
            virtualCardPhrase,
            """
            {"title":"Виртуальная карта","sections":[{"heading":null,"items":[\
            {"text":"Заменить иконку на главном экране","task":true,"time":null,"children":[]},\
            {"text":"Проверить лимиты","task":true,"time":null,"children":[]}]}]}
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
            messages.append(ChatMessage(role: .user, content: taken(request.takenTitles) + request.text))
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

    /// Spec 18.7: no two stickers on screen under one title. The note goes into
    /// the last turn, so that the turns before it stay the same from request to request.
    static func taken(_ titles: [String]) -> String {
        let named = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !named.isEmpty else { return "" }
        let list = named.map { "«\($0)»" }.joined(separator: ", ")
        return "Заголовки, которые уже есть на экране: \(list). Возьми другой.\n\nДиктовка: "
    }

    /// The conversation after an answer that could not be read: one more try (spec 8.3).
    public static func retry(_ messages: [ChatMessage], after answer: String) -> [ChatMessage] {
        messages + [ChatMessage(role: .assistant, content: answer), ChatMessage(role: .user, content: reminder)]
    }
}

/// Reads a model's answer as a plan (spec 8.3).
public enum PlanParser {
    /// - Throws: `StructurerError.invalidAnswer` when there is no plan in the answer,
    ///   `StructurerError.nothingToDo` when the plan is there and has no items.
    public static func parse(_ answer: String) throws -> NotePlan {
        // Models like to wrap JSON in a code fence or a sentence: take the outermost object.
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end else {
            throw StructurerError.invalidAnswer
        }
        let json = Data(answer[start...end].utf8)
        guard let plan = try? JSONDecoder().decode(NotePlan.self, from: json).normalized() else {
            throw StructurerError.invalidAnswer
        }
        // A greeting or a microphone check alone: the model rightly found nothing to do.
        guard !plan.isEmpty else { throw StructurerError.nothingToDo }
        return plan
    }
}
