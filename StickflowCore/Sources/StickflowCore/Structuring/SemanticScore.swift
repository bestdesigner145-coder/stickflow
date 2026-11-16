// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// One phrase of the set that checks structuring by meaning (spec 18.3): what
/// was said, which items must come out of it and how they must be grouped.
///
/// An item is named by needles: pieces of words that must all be in it, in any
/// wording. `a|b` is either piece. "ё" is read as "е", case does not matter.
public struct SemanticCase: Decodable, Equatable, Sendable {
    public struct Group: Decodable, Equatable, Sendable {
        /// Either of these must be in the section's heading; `nil` — any heading or none.
        public var heading: [String]?
        public var items: [[String]]

        public init(heading: [String]? = nil, items: [[String]]) {
            self.heading = heading
            self.items = items
        }
    }

    public var input: String
    /// No groups at all: nothing in the phrase is a thing to do.
    public var groups: [Group]
    /// Items that may be there or not; they are not counted as extra.
    public var optional: [[String]]
    /// What must not get into any item: greetings, words about the dictation itself.
    public var junk: [String]
    /// False when more than one grouping is reasonable: grouping is not scored then.
    public var scoresGrouping: Bool

    public init(input: String, groups: [Group], optional: [[String]] = [], junk: [String] = [], scoresGrouping: Bool = true) {
        self.input = input
        self.groups = groups
        self.optional = optional
        self.junk = junk
        self.scoresGrouping = scoresGrouping
    }

    private enum CodingKeys: String, CodingKey {
        case input, groups, optional, junk, scoresGrouping
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decode(String.self, forKey: .input)
        groups = try container.decode([Group].self, forKey: .groups)
        optional = try container.decodeIfPresent([[String]].self, forKey: .optional) ?? []
        junk = try container.decodeIfPresent([String].self, forKey: .junk) ?? []
        scoresGrouping = try container.decodeIfPresent(Bool.self, forKey: .scoresGrouping) ?? true
    }

    /// How one plan did on this phrase.
    public struct Verdict: Equatable, Sendable {
        public var expected = 0
        public var found = 0
        /// Items of the plan that answer to nothing expected.
        public var extra = 0
        /// Items of the plan with a greeting or words about the dictation in them.
        public var junk = 0
        /// Everything found, items of one group together, groups apart, named groups named.
        public var grouped = false
    }

    static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    static func has(_ needles: [String], in text: String) -> Bool {
        needles.allSatisfy { needle in
            needle.split(separator: "|").contains { text.contains(fold(String($0))) }
        }
    }

    public func verdict(for plan: NotePlan) -> Verdict {
        struct Entry {
            var section: Int
            var text: String
            var whole: String
            var used = false
        }
        var entries: [Entry] = []
        for (index, section) in plan.sections.enumerated() {
            for item in section.items {
                let text = Self.fold(item.text + " " + (item.time ?? ""))
                entries.append(Entry(section: index, text: text, whole: text + " " + Self.fold(item.children.joined(separator: " "))))
            }
        }
        var verdict = Verdict()
        // Where each expected item ended up: the section, or nil when it is not in the plan.
        var places: [[Int?]] = []
        for group in groups {
            var row: [Int?] = []
            for needles in group.items {
                verdict.expected += 1
                // An item of its own first; a thing said as a detail of another item counts too.
                if let own = entries.firstIndex(where: { !$0.used && Self.has(needles, in: $0.text) }) {
                    entries[own].used = true
                    row.append(entries[own].section)
                } else if let inside = entries.firstIndex(where: { Self.has(needles, in: $0.whole) }) {
                    row.append(entries[inside].section)
                } else {
                    row.append(nil)
                }
            }
            verdict.found += row.compactMap { $0 }.count
            places.append(row)
        }
        for index in entries.indices where !entries[index].used {
            if optional.contains(where: { Self.has($0, in: entries[index].whole) }) { entries[index].used = true }
        }
        verdict.extra = entries.filter { !$0.used }.count
        verdict.junk = entries.filter { entry in junk.contains { entry.whole.contains(Self.fold($0)) } }.count
        verdict.grouped = verdict.found == verdict.expected && isGrouped(places, in: plan)
        return verdict
    }

    private func isGrouped(_ places: [[Int?]], in plan: NotePlan) -> Bool {
        var taken: Set<Int> = []
        for (group, row) in zip(groups, places) {
            let sections = Set(row.compactMap { $0 })
            guard sections.count <= 1 else { return false }
            guard let section = sections.first else { continue }
            // Two groups in one section are not groups.
            guard taken.insert(section).inserted else { return false }
            if let heading = group.heading {
                // One topic for the whole note may be its title instead of a heading.
                var name = plan.sections[section].heading ?? ""
                if plan.sections.count == 1 { name += " " + plan.title }
                guard heading.contains(where: { Self.has([$0], in: Self.fold(name)) }) else { return false }
            }
        }
        return true
    }
}

/// How a structurer did on the whole set (spec 8.6 with the additions of 18.3).
public struct SemanticScore: Equatable, Sendable {
    public var cases = 0
    /// Cases with an answer that could be read (or, rightly, with nothing to do).
    public var answered = 0
    public var groupingCases = 0
    public var grouped = 0
    public var expected = 0
    public var found = 0
    public var extra = 0
    public var junk = 0
    /// Items the model repeated, before the cleaning took them out.
    public var duplicates = 0
    public var mustKeep = 0
    public var kept = 0
    public var items = 0
    public var words = 0
    public var latencies: [Double] = []

    public init() {}

    /// - Parameters:
    ///   - raw: the plan as the structurer gave it, `nil` when there is none.
    ///   - failed: there is no plan because of a failure, not because there was nothing to do.
    public mutating func record(_ semantic: SemanticCase, raw: NotePlan?, failed: Bool, seconds: Double) {
        cases += 1
        latencies.append(seconds)
        let tokens = StructuringMetrics.mustKeep(in: semantic.input)
        mustKeep += tokens.count
        if semantic.scoresGrouping { groupingCases += 1 }
        let nothingExpected = semantic.groups.isEmpty
        guard let raw else {
            // "Nothing to do" is the right answer to a phrase with nothing to do in it.
            if nothingExpected, !failed {
                answered += 1
                grouped += semantic.scoresGrouping ? 1 : 0
            }
            return
        }
        answered += 1
        let (plan, merged) = PlanCleaner.clean(raw)
        duplicates += merged
        let verdict = semantic.verdict(for: plan)
        expected += verdict.expected
        found += verdict.found
        extra += verdict.extra
        junk += verdict.junk
        if semantic.scoresGrouping, verdict.grouped, !nothingExpected || plan.isEmpty { grouped += 1 }
        kept += StructuringMetrics.kept(tokens, in: plan)
        items += plan.items.count
        words += plan.items.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    public var answeredShare: Double { cases == 0 ? 0 : Double(answered) / Double(cases) }
    public var groupedShare: Double { groupingCases == 0 ? 0 : Double(grouped) / Double(groupingCases) }
    public var foundShare: Double { expected == 0 ? 0 : Double(found) / Double(expected) }
    public var keptShare: Double { mustKeep == 0 ? 1 : Double(kept) / Double(mustKeep) }
    public var wordsPerItem: Double { items == 0 ? 0 : Double(words) / Double(items) }

    public func latency(percentile share: Double) -> Double {
        StructuringMetrics.percentile(share, of: latencies)
    }
}
