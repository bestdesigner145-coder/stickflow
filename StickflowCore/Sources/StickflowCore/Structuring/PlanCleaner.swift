// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// What is done to every plan after a structurer has answered (spec 18.2): an
/// item that repeats another or is a part of it is merged into it, a greeting
/// is not a task, a detail does not repeat its own item.
public enum PlanCleaner {
    static let stopWords: Set<String> = [
        "и", "в", "во", "на", "с", "со", "к", "ко", "по", "для", "за", "из", "от", "до", "о", "об", "про", "у", "а", "но",
        "же", "бы", "ли", "не", "это", "the", "a", "an", "to", "of", "in", "on", "for", "and", "at", "with",
    ]
    static let greetings: Set<String> = [
        "привет", "приветик", "здравствуй", "здравствуйте", "добрый", "доброе", "доброй", "день", "утро", "вечер", "всем",
        "алло", "hello", "hi", "hey", "good", "morning", "evening", "everyone",
    ]

    /// Lowercase words of letters and digits, "ё" read as "е".
    public static func words(of text: String) -> [String] {
        var result: [String] = []
        var word = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                word.append(character == "ё" ? "е" : character)
            } else if !word.isEmpty {
                result.append(word)
                word = ""
            }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }

    /// A word without its ending, roughly: enough to see "карту" and "карта" as one.
    /// Anything with a digit stays whole: 2.1 and 2.2 are different things.
    static func stem(_ word: String) -> String {
        if word.contains(where: \.isNumber) { return word }
        switch word.count {
        case ...3: return word
        case 4...5: return String(word.dropLast(1))
        default: return String(word.dropLast(2))
        }
    }

    /// The meaningful words of a text, without endings and without order.
    public static func stems(of text: String) -> Set<String> {
        Set(words(of: text).filter { !stopWords.contains($0) }.map(stem))
    }

    /// "Привет", "Добрый день": said to the microphone, not a thing to do.
    static func isGreeting(_ item: NotePlan.Item) -> Bool {
        let all = words(of: item.text)
        return !all.isEmpty && all.allSatisfy { greetings.contains($0) } && item.children.isEmpty && item.time == nil
    }

    /// One item says what the other says, or a part of it. Two different times
    /// keep two items apart: a call at 11 and the same call at 15 are two calls.
    static func isSame(_ first: NotePlan.Item, _ second: NotePlan.Item) -> Bool {
        let one = stems(of: first.text)
        let other = stems(of: second.text)
        guard !one.isEmpty, !other.isEmpty, one.isSubset(of: other) || other.isSubset(of: one) else { return false }
        guard let early = first.time, let late = second.time else { return true }
        return early == late
    }

    /// The more exact wording stays, in the place of the first.
    static func merge(_ first: NotePlan.Item, _ second: NotePlan.Item) -> NotePlan.Item {
        let text = stems(of: second.text).count > stems(of: first.text).count ? second.text : first.text
        return NotePlan.Item(
            text: text, task: first.task || second.task, time: first.time ?? second.time, children: first.children + second.children
        )
    }

    /// Details without those that repeat the item or each other.
    static func tidyingChildren(_ item: NotePlan.Item) -> NotePlan.Item {
        let own = stems(of: item.text)
        var seen: [Set<String>] = []
        var item = item
        item.children = item.children.filter { child in
            let these = stems(of: child)
            guard !these.isEmpty, !these.isSubset(of: own), !seen.contains(these) else { return false }
            seen.append(these)
            return true
        }
        return item
    }

    /// - Returns: the plan without repeats and greetings, and how many items were merged away.
    public static func clean(_ plan: NotePlan) -> (plan: NotePlan, merged: Int) {
        var kept: [(section: Int, item: NotePlan.Item)] = []
        var merged = 0
        for (index, section) in plan.sections.enumerated() {
            for item in section.items where !isGreeting(item) {
                if let twin = kept.firstIndex(where: { isSame($0.item, item) }) {
                    kept[twin].item = merge(kept[twin].item, item)
                    merged += 1
                } else {
                    kept.append((index, item))
                }
            }
        }
        var sections: [NotePlan.Section] = []
        for (index, section) in plan.sections.enumerated() {
            let items = kept.filter { $0.section == index }.map { tidyingChildren($0.item) }
            if !items.isEmpty { sections.append(NotePlan.Section(heading: section.heading, items: items)) }
        }
        return (NotePlan(title: plan.title, sections: sections), merged)
    }
}

public extension NotePlan {
    /// The plan without repeated items, greetings and details that repeat their item (spec 18.2).
    func cleaned() -> NotePlan {
        PlanCleaner.clean(self).plan
    }
}
