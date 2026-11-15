// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// The structurer that works at once and without any model (spec 8.1, "Правила"):
/// drops filler words, cuts dictated text into items at "потом", "ещё" and full
/// stops, pulls the time out ("в три" is 15:00), moves "если успею" into a section
/// of its own and turns what follows "там" into details.
///
/// It works on words, not on meaning: it never rephrases and never adds anything.
/// Russian first, with the same basics for English.
public struct RuleStructurer: Structurer {
    public let id = "rules"
    public let displayName = "Rules"
    public let isLocal = true

    public init() {}

    public func health() async -> StructurerHealth { .ready }

    public func structure(_ request: StructureRequest) async throws -> NotePlan {
        let plan = Self.plan(from: request.text)
        guard !plan.isEmpty else { throw StructurerError.nothingToDo }
        return plan
    }

    // MARK: Vocabulary

    private static let punctuation: Set<String> = [",", ".", "!", "?", ";", ":", "\n", "—", "–"]
    private static let sentenceEnd: Set<String> = [".", "!", "?", ";", "\n"]
    private static let quotes: Set<Character> = ["«", "»", "\"", "“", "”", "„", "(", ")"]

    private static let connectors: [[String]] = [
        ["после", "этого"], ["после", "чего"], ["а", "потом"], ["потом"], ["затем"], ["еще"], ["также"], ["плюс"], ["далее"], ["дальше"],
        ["after", "that"], ["and", "then"], ["then"], ["also"], ["plus"],
    ]
    private static let optionalMarkers: [[String]] = [
        ["если", "успею"], ["если", "успеем"], ["если", "останется", "время"], ["если", "будет", "время"], ["по", "возможности"],
        ["желательно"],
        ["if", "i", "have", "time"], ["if", "there", "is", "time"], ["if", "possible"], ["if", "time", "permits"],
    ]
    private static let fillerPhrases: [[String]] = [
        ["как", "бы"], ["в", "общем"], ["в", "принципе"], ["так", "сказать"], ["мне", "надо"], ["мне", "нужно"], ["нам", "надо"],
        ["нам", "нужно"],
        ["надо", "бы"], ["надо", "будет"], ["нужно", "будет"], ["это", "важно"], ["это", "срочно"], ["на", "сегодня"],
        ["you", "know"], ["i", "mean"], ["i", "need", "to"], ["i", "have", "to"], ["we", "need", "to"], ["need", "to"], ["have", "to"],
        ["kind", "of"], ["sort", "of"],
    ]
    private static let fillers: Set<String> = [
        "условно", "ну", "наверное", "знаешь", "слушай", "собственно", "сначала", "сперва", "надо", "нужно",
        "необходимо", "сегодня", "блин", "допустим", "кстати", "um", "uh", "basically", "today", "okay", "ok",
    ]
    /// Fillers only at the start of a clause or after punctuation; elsewhere they
    /// mean something ("в 2 раза короче").
    private static let looseFillers: Set<String> = [
        "короче", "типа", "так", "вот", "значит", "скажем", "просто", "like", "so", "well", "actually", "first",
    ]
    private static let leadingJunk: Set<String> = ["и", "а", "да", "но", "ой", "ах", "and", "but", "oh"]
    /// After these a time is a deadline or a span, not the moment of the item.
    private static let notAMoment: Set<String> = ["до", "к", "с", "после", "от", "by", "until", "before", "after", "from"]
    private static let detailMarkers: Set<String> = ["там"]
    private static let childSeparators: Set<String> = ["и", "and", "или", "or"]
    /// "в 2 раза" is not a time.
    private static let countNouns = [
        "раз", "этап", "заход", "шаг", "экран", "пункт", "част", "слов", "строк", "стр", "колон", "ряд", "штук", "слайд", "цвет", "вариант",
        "файл", "человек", "недел", "месяц", "times", "steps", "parts", "screens",
    ]
    private static let hours: [String: Int] = [
        "час": 1, "один": 1, "два": 2, "три": 3, "четыре": 4, "пять": 5, "шесть": 6, "семь": 7, "восемь": 8, "девять": 9, "десять": 10,
        "одиннадцать": 11, "двенадцать": 12, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]
    private static let noon: Set<String> = ["полдень", "noon"]
    private static let hourWords: Set<String> = ["часов", "часа", "час", "o'clock"]
    private static let morning: Set<String> = ["утра", "am", "a.m"]
    private static let afternoon: Set<String> = ["дня", "вечера", "pm", "p.m"]
    private static let night: Set<String> = ["ночи"]
    private static let nounToVerb: [String: String] = ["созвон": "Созвониться"]
    private static let verbsEndingInSt: Set<String> = [
        "есть", "съесть", "поесть", "сесть", "класть", "упасть", "попасть", "прочесть", "учесть", "украсть",
    ]
    private static let verbSuffixesCh = ["мочь", "лечь", "беречь", "стричь", "печь", "влечь", "жечь", "сечь"]
    private static let verbSuffixesTi = [
        "йти", "дти", "нести", "везти", "вести", "расти", "спасти", "мести", "трясти", "плести", "грести", "цвести", "брести",
    ]
    private static let notVerbs: Set<String> = [
        "пять", "девять", "десять", "мать", "память", "сеть", "опять", "пусть", "хоть", "треть", "путь", "суть", "чуть", "зять", "кровать",
        "печать", "двести", "вести", "страсти", "тетрадь", "ночь", "дочь", "речь", "мелочь", "полночь", "пути", "почти",
    ]

    // MARK: Words

    static func tokenize(_ text: String) -> [String] {
        let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var tokens: [String] = []
        var word = ""
        func flush() {
            if !word.isEmpty {
                tokens.append(word)
                word = ""
            }
        }
        for (index, character) in characters.enumerated() {
            let piece = String(character)
            if punctuation.contains(piece) {
                // 15:30 and 2.1.3 stay one word.
                let joinsDigits = (piece == ":" || piece == ".") && (word.last.map(isDigit) ?? false)
                    && index + 1 < characters.count && isDigit(characters[index + 1])
                if joinsDigits {
                    word.append(character)
                } else {
                    flush()
                    tokens.append(piece)
                }
            } else if character.isWhitespace || quotes.contains(character) {
                flush()
            } else {
                word.append(character)
            }
        }
        flush()
        return tokens
    }

    private static func isDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9" && character.isASCII
    }

    private static func isNumber(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy(isDigit)
    }

    /// The form words are compared in.
    private static func key(_ token: String) -> String {
        token.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private static func isWord(_ token: String) -> Bool {
        !punctuation.contains(token)
    }

    /// A Russian infinitive, by its ending. Nouns that end the same way are listed.
    static func isInfinitive(_ token: String) -> Bool {
        let word = key(token)
        let isCyrillic = word.unicodeScalars.allSatisfy { (0x430...0x44F).contains($0.value) || $0 == "-" }
        guard word.count >= 3, !notVerbs.contains(word), isCyrillic else { return false }
        if word.hasSuffix("ться") || word.hasSuffix("тись") || word.hasSuffix("чься") { return true }
        if word.hasSuffix("дцать") || word.hasSuffix("ость") { return false }
        if word.hasSuffix("сть") { return verbsEndingInSt.contains(word) }
        if word.hasSuffix("ть") { return true }
        if word.hasSuffix("чь") { return verbSuffixesCh.contains { word.hasSuffix($0) } }
        if word.hasSuffix("ти") { return verbSuffixesTi.contains { word.hasSuffix($0) } }
        return false
    }

    /// Length of the phrase from `phrases` that starts at `index`, or 0.
    private static func match(_ phrases: [[String]], in tokens: [String], at index: Int) -> Int {
        for phrase in phrases where index + phrase.count <= tokens.count {
            if phrase.indices.allSatisfy({ key(tokens[index + $0]) == phrase[$0] }) {
                return phrase.count
            }
        }
        return 0
    }

    /// Cuts at every phrase; the phrases themselves go.
    private static func split(_ tokens: [String], at phrases: [[String]]) -> [[String]] {
        var parts: [[String]] = []
        var current: [String] = []
        var index = 0
        while index < tokens.count {
            let matched = match(phrases, in: tokens, at: index)
            if matched > 0 {
                parts.append(current)
                current = []
                index += matched
            } else {
                current.append(tokens[index])
                index += 1
            }
        }
        parts.append(current)
        return parts
    }

    /// "желательно ещё заказать воду": the connector must not cut the marker off
    /// from what it marks.
    private static func droppingConnectorsAfterOptional(_ tokens: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            let matched = match(optionalMarkers, in: tokens, at: index)
            if matched > 0 {
                result.append(contentsOf: tokens[index..<index + matched])
                index += matched
                index += match(connectors, in: tokens, at: index)
            } else {
                result.append(tokens[index])
                index += 1
            }
        }
        return result
    }

    private static func strippingFillers(_ tokens: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            let matched = match(fillerPhrases, in: tokens, at: index)
            if matched > 0 {
                index += matched
                continue
            }
            let word = key(tokens[index])
            let startsClause = result.last.map { !isWord($0) } ?? true
            if fillers.contains(word) || (looseFillers.contains(word) && startsClause) {
                index += 1
                continue
            }
            result.append(tokens[index])
            index += 1
        }
        return result
    }

    /// Drops punctuation and dangling conjunctions at both ends and doubled
    /// punctuation inside.
    private static func trimmed(_ tokens: [String]) -> [String] {
        var tokens = tokens
        while let first = tokens.first, !isWord(first) || leadingJunk.contains(key(first)) {
            tokens.removeFirst()
        }
        while let last = tokens.last, !isWord(last) || leadingJunk.contains(key(last)) {
            tokens.removeLast()
        }
        var result: [String] = []
        for token in tokens {
            if !isWord(token), let previous = result.last, !isWord(previous) { continue }
            result.append(token)
        }
        return result
    }

    private static func joined(_ tokens: [String]) -> String {
        var text = ""
        for token in tokens {
            if isWord(token) {
                text += (text.isEmpty ? "" : " ") + token
            } else if token == "—" || token == "–" {
                text += " " + token
            } else {
                text += token
            }
        }
        return text
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: Time

    /// "15:30" or "9:05"; after a preposition also "15.30".
    private static func clock(_ token: String, separators: [Character]) -> (hour: Int, minute: Int)? {
        for separator in separators {
            guard let at = token.firstIndex(of: separator) else { continue }
            let hourText = String(token[..<at])
            let minuteText = String(token[token.index(after: at)...])
            if isNumber(hourText), isNumber(minuteText), hourText.count <= 2, minuteText.count == 2,
               let hour = Int(hourText), let minute = Int(minuteText), hour < 24, minute < 60 {
                return (hour, minute)
            }
        }
        return nil
    }

    /// Finds "в три", "в 11", "в 15:30", "at 3 pm" and takes it out of the words.
    static func extractTime(from tokens: [String]) -> (time: String?, rest: [String]) {
        for index in tokens.indices {
            let word = key(tokens[index])
            let hasPreposition = (word == "в" || word == "at") && index + 1 < tokens.count
            let start = hasPreposition ? index + 1 : index
            let exact = clock(tokens[start], separators: hasPreposition ? [":", "."] : [":"])
            if exact == nil, !hasPreposition { continue }
            // "до 18:00" is a deadline; it stays in the text.
            if !hasPreposition, index > 0, notAMoment.contains(key(tokens[index - 1])) { continue }

            var hour: Int
            var minute = 0
            var isExplicit = false
            var end = start + 1
            if let exact {
                hour = exact.hour
                minute = exact.minute
                isExplicit = true
            } else {
                let spoken = key(tokens[start])
                if isNumber(spoken), spoken.count <= 2, let value = Int(spoken), value < 24 {
                    hour = value
                } else if let value = hours[spoken] {
                    hour = value
                } else if noon.contains(spoken) {
                    hour = 12
                    isExplicit = true
                } else {
                    continue
                }
                if spoken != "час", !noon.contains(spoken), end < tokens.count, hourWords.contains(key(tokens[end])) {
                    end += 1
                }
            }
            var qualifier = end < tokens.count ? key(tokens[end]) : ""
            while qualifier.hasSuffix(".") {
                qualifier.removeLast()
            }
            if morning.contains(qualifier) || night.contains(qualifier) {
                end += 1
                if hour == 12 { hour = 0 }
            } else if afternoon.contains(qualifier) {
                end += 1
                if hour < 12 { hour += 12 }
            } else if !isExplicit {
                if countNouns.contains(where: { qualifier.hasPrefix($0) }) { continue }
                // A working day: "в три" is 15:00.
                if (1...7).contains(hour) { hour += 12 }
            }
            guard hour <= 23 else { continue }
            let time = (hour < 10 ? "0" : "") + String(hour) + ":" + (minute < 10 ? "0" : "") + String(minute)
            return (time, Array(tokens[..<index]) + Array(tokens[end...]))
        }
        return (nil, tokens)
    }

    // MARK: Items

    /// "поправить шапку, заменить фото и проверить мобилку" is three actions.
    private static func splitActions(_ tokens: [String]) -> [[String]] {
        var parts: [[String]] = []
        var current: [String] = []
        for (index, token) in tokens.enumerated() {
            let word = key(token)
            let isSeparator = token == "," || word == "и" || word == "and"
            let wordCount = current.filter(isWord).count
            var startsAction = index + 1 < tokens.count && isInfinitive(tokens[index + 1])
                && current.contains(where: isInfinitive) && wordCount >= 2
            // "созвон в 9 утра, в полдень обед": two moments are two items.
            if token == ",", !startsAction, extractTime(from: current).time != nil {
                let rest = tokens[(index + 1)...]
                let segment = rest.prefix { $0 != "," }
                startsAction = extractTime(from: Array(segment)).time != nil
            }
            if isSeparator, startsAction {
                parts.append(current)
                current = []
            } else {
                current.append(token)
            }
        }
        parts.append(current)
        return parts
    }

    private static func details(from tokens: [String]) -> [String] {
        var parts: [[String]] = []
        var current: [String] = []
        for token in tokens {
            if token == "," || childSeparators.contains(key(token)) {
                parts.append(current)
                current = []
            } else {
                current.append(token)
            }
        }
        parts.append(current)
        return parts.map(trimmed).filter { !$0.isEmpty }.map(joined)
    }

    private static func makeItem(from action: [String]) -> NotePlan.Item? {
        var tokens = action
        var details: [String] = []
        if let marker = tokens.indices.first(where: { $0 > 0 && detailMarkers.contains(key(tokens[$0])) }) {
            details = Array(tokens[(marker + 1)...])
            tokens = Array(tokens[..<marker])
        }
        let timed = extractTime(from: strippingFillers(tokens))
        tokens = trimmed(timed.rest)
        guard let first = tokens.first else { return nil }
        if let verb = nounToVerb[key(first)] {
            tokens[0] = verb
        } else if tokens.count > 1, let last = tokens.last, isInfinitive(last), !tokens.dropLast().contains(where: isInfinitive) {
            // "пост написать" reads better as "написать пост".
            tokens = [last] + tokens.dropLast()
        }
        let detailLines = Self.details(from: strippingFillers(details))
            .map { NotePlan.clip($0, to: NotePlan.Limit.child) }
            .prefix(NotePlan.Limit.children)
        return NotePlan.Item(
            text: NotePlan.clip(capitalized(joined(tokens)), to: NotePlan.Limit.item),
            task: true,
            time: timed.time,
            children: Array(detailLines)
        )
    }

    // MARK: Plan

    static func isRussian(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x410...0x44F).contains($0.value) || $0.value == 0x401 || $0.value == 0x451 }
    }

    /// The whole pipeline. An empty plan means there was nothing to do in the text.
    public static func plan(from text: String) -> NotePlan {
        let russian = isRussian(text)
        var plain: [NotePlan.Item] = []
        var optional: [NotePlan.Item] = []
        var headed: [NotePlan.Section] = []

        var sentences: [[String]] = [[]]
        for token in tokenize(text) {
            if sentenceEnd.contains(token) {
                sentences.append([])
            } else {
                sentences[sentences.count - 1].append(token)
            }
        }
        for var sentence in sentences {
            // "По лендингу Маши: …" names the section for the rest of the sentence.
            var section: Int?
            if let colon = sentence.firstIndex(of: ":") {
                let topic = trimmed(strippingFillers(Array(sentence[..<colon])))
                if (1...5).contains(topic.count), !topic.contains(where: isInfinitive) {
                    let heading = NotePlan.clip(capitalized(joined(topic)), to: NotePlan.Limit.heading)
                    sentence = Array(sentence[(colon + 1)...])
                    if let existing = headed.firstIndex(where: { $0.heading?.lowercased() == heading.lowercased() }) {
                        section = existing
                    } else {
                        headed.append(NotePlan.Section(heading: heading, items: []))
                        section = headed.count - 1
                    }
                }
            }
            for clause in split(droppingConnectorsAfterOptional(sentence), at: connectors) {
                let parts = split(clause, at: optionalMarkers)
                for (index, part) in parts.enumerated() {
                    // "…, если успею, X": what follows is optional; "X, если успею": what precedes is.
                    let isOptional = parts.count > 1 && (index > 0 || trimmed(strippingFillers(parts[1])).isEmpty)
                    for action in splitActions(trimmed(part)) {
                        guard let item = makeItem(from: action) else { continue }
                        if isOptional {
                            optional.append(item)
                        } else if let section {
                            headed[section].items.append(item)
                        } else {
                            plain.append(item)
                        }
                    }
                }
            }
        }

        var sections: [NotePlan.Section] = []
        if !plain.isEmpty {
            sections.append(NotePlan.Section(heading: nil, items: plain))
        }
        let named = headed.filter { !$0.items.isEmpty }
        sections.append(contentsOf: named)
        if !optional.isEmpty {
            sections.append(NotePlan.Section(heading: russian ? "Если успею" : "If there is time", items: optional))
        }
        var title = russian ? "План на сегодня" : "Plan for today"
        if named.count == 1, plain.isEmpty, let only = named[0].heading {
            title = only
        }
        return NotePlan(title: NotePlan.clip(title, to: NotePlan.Limit.title), sections: sections)
    }
}
