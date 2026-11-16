// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// What a structurer makes of dictated or typed text (spec 8.3): a title and
/// sections of short items. The JSON form is the one a language model answers in.
public struct NotePlan: Equatable, Sendable, Codable {
    public struct Item: Equatable, Sendable, Codable {
        public var text: String
        public var task: Bool
        /// "HH:MM", or `nil`.
        public var time: String?
        public var children: [String]

        public init(text: String, task: Bool = true, time: String? = nil, children: [String] = []) {
            self.text = text
            self.task = task
            self.time = time
            self.children = children
        }

        // swiftlint:disable:next nesting
        private enum CodingKeys: String, CodingKey {
            case text, task, time, children
        }

        /// The schema requires only `text` and `task`.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            task = try container.decode(Bool.self, forKey: .task)
            time = try container.decodeIfPresent(String.self, forKey: .time)
            children = try container.decodeIfPresent([String].self, forKey: .children) ?? []
        }
    }

    public struct Section: Equatable, Sendable, Codable {
        public var heading: String?
        public var items: [Item]

        public init(heading: String? = nil, items: [Item]) {
            self.heading = heading
            self.items = items
        }
    }

    public var title: String
    public var sections: [Section]

    public init(title: String, sections: [Section]) {
        self.title = title
        self.sections = sections
    }

    /// Limits of the schema (spec 8.3).
    public enum Limit {
        public static let title = 40
        public static let heading = 32
        public static let item = 80
        public static let child = 48
        public static let children = 6
    }

    public var items: [Item] { sections.flatMap(\.items) }

    /// Nothing to stick.
    public var isEmpty: Bool { items.isEmpty }

    /// Trims, drops what is empty, cuts what is too long and throws away a time
    /// that is not "HH:MM" (spec 8.3). A model's answer goes through this before use.
    public func normalized() -> NotePlan {
        func clean(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cleanSections = sections.compactMap { section -> Section? in
            let items = section.items.compactMap { item -> Item? in
                let text = clean(item.text)
                guard !text.isEmpty else { return nil }
                let children = item.children.map(clean).filter { !$0.isEmpty }
                    .prefix(Limit.children).map { Self.clip($0, to: Limit.child) }
                let time = item.time.map(clean).flatMap { Self.isClock($0) ? $0 : nil }
                return Item(text: Self.clip(text, to: Limit.item), task: item.task, time: time, children: Array(children))
            }
            guard !items.isEmpty else { return nil }
            let heading = section.heading.map(clean).flatMap { $0.isEmpty ? nil : Self.clip($0, to: Limit.heading) }
            return Section(heading: heading, items: items)
        }
        return NotePlan(title: Self.clip(clean(title), to: Limit.title), sections: cleanSections)
    }

    /// The sticker's lines: a heading per named section, a task or a bullet per
    /// item with its time at the end after a dash, details as nested bullets.
    public func blocks() -> [Block] {
        var blocks: [Block] = []
        for section in sections {
            if let heading = section.heading, !heading.isEmpty {
                blocks.append(Block(kind: .heading2, text: heading))
            }
            for item in section.items {
                let text = item.time.map { "\(item.text) — \($0)" } ?? item.text
                blocks.append(Block(kind: item.task ? .todo : .bullet, text: text))
                for child in item.children {
                    blocks.append(Block(kind: .bullet, text: child, indent: 1))
                }
            }
        }
        return blocks
    }

    /// "09:30" and the like.
    static func isClock(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 5, scalars[2] == ":" else { return false }
        let digits = [scalars[0], scalars[1], scalars[3], scalars[4]]
        guard digits.allSatisfy({ (48...57).contains($0.value) }) else { return false }
        let hour = Int((scalars[0].value - 48) * 10 + scalars[1].value - 48)
        let minute = Int((scalars[3].value - 48) * 10 + scalars[4].value - 48)
        return hour < 24 && minute < 60
    }

    /// Cuts at a word where it can and marks the cut with an ellipsis.
    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        var cut = String(text.prefix(limit - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        while let last = cut.last, last == " " || last == "," {
            cut.removeLast()
        }
        return cut + "…"
    }
}

/// What a structurer is asked to do (spec 8.2).
public struct StructureRequest: Sendable {
    public enum Mode: Sendable {
        case new
        case append(existing: NotePlan)
    }

    public var text: String
    public var mode: Mode
    /// The compression rules from the settings (spec 8.4); a rule-based structurer ignores them.
    public var rules: String
    public var locale: Locale
    public var now: Date
    /// Read an hour from 1 to 7 said without "утра" or "дня" as afternoon
    /// ("в три" is 15:00). Off: such an hour is left as it was said.
    public var ambiguousHoursAreAfternoon = false

    public init(text: String, mode: Mode = .new, rules: String = "", locale: Locale = .current, now: Date = Date()) {
        self.text = text
        self.mode = mode
        self.rules = rules
        self.locale = locale
        self.now = now
    }
}

public enum StructurerHealth: Equatable, Sendable {
    case ready
    /// Not usable now; the text says why, for the settings.
    case unavailable(String)
}

public enum StructurerError: Error, Equatable, Sendable {
    /// Nothing in the text looked like something to do.
    case nothingToDo
    case timedOut
    case invalidAnswer
    /// The provider lacks something of the user's: a key, or the key was refused.
    case notConfigured
    /// The service answered with this HTTP status.
    case serverError(Int)
}

/// Turns raw text into a plan (spec 8.1). The rules, a local model and the
/// cloud providers all sit behind this, and tests replace it.
public protocol Structurer: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// True when the text never leaves the Mac.
    var isLocal: Bool { get }
    func health() async -> StructurerHealth
    func structure(_ request: StructureRequest) async throws -> NotePlan
}
