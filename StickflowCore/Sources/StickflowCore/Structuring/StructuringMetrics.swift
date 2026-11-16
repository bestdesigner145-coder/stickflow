// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// How well a structurer did on the golden set (spec 8.6): whether it answered,
/// whether it found as many tasks as expected, whether names, numbers and times
/// came through as they were said, how long its items are and how long it took.
public struct StructuringScore: Equatable, Sendable {
    public var cases = 0
    /// Cases that gave a plan at all.
    public var answered = 0
    /// Cases with as many items as the expected plan has.
    public var countMatches = 0
    /// Names, numbers and times that had to come through, and how many did.
    public var mustKeep = 0
    public var kept = 0
    public var items = 0
    public var words = 0
    /// Seconds per case, answered or not.
    public var latencies: [Double] = []

    public init() {}

    public mutating func record(input: String, expected: NotePlan, plan: NotePlan?, seconds: Double) {
        cases += 1
        latencies.append(seconds)
        let tokens = StructuringMetrics.mustKeep(in: input)
        mustKeep += tokens.count
        guard let plan else { return }
        answered += 1
        if plan.items.count == expected.items.count { countMatches += 1 }
        kept += StructuringMetrics.kept(tokens, in: plan)
        items += plan.items.count
        words += plan.items.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    public var answeredShare: Double { cases == 0 ? 0 : Double(answered) / Double(cases) }
    public var countMatchShare: Double { cases == 0 ? 0 : Double(countMatches) / Double(cases) }
    public var keptShare: Double { mustKeep == 0 ? 1 : Double(kept) / Double(mustKeep) }
    public var wordsPerItem: Double { items == 0 ? 0 : Double(words) / Double(items) }

    /// The value below which `share` of the latencies fall, e.g. 0.5 and 0.95.
    public func latency(percentile share: Double) -> Double {
        guard !latencies.isEmpty else { return 0 }
        let sorted = latencies.sorted()
        let index = Int((Double(sorted.count - 1) * min(max(share, 0), 1)).rounded())
        return sorted[index]
    }
}

public enum StructuringMetrics {
    /// What must come through exactly: capitalised words inside a sentence
    /// (names) and everything with a digit in it (numbers, times, versions).
    public static func mustKeep(in input: String) -> [String] {
        let tokens = RuleStructurer.tokenize(input)
        var result: [String] = []
        for (index, token) in tokens.enumerated() {
            if token.contains(where: \.isNumber) {
                result.append(token)
            } else if index > 0, let first = token.first, first.isUppercase, ![".", "!", "?", ":", "\n"].contains(tokens[index - 1]) {
                result.append(token)
            }
        }
        return result
    }

    /// How many of `tokens` are in the plan. A time may have been rewritten the
    /// plan's way: "18.30" as "18:30", "11" as "11:00", "8" (вечера) as "20:00".
    public static func kept(_ tokens: [String], in plan: NotePlan) -> Int {
        var parts = [plan.title]
        for section in plan.sections {
            parts.append(section.heading ?? "")
            for item in section.items {
                parts.append(item.text)
                parts.append(item.time ?? "")
                parts.append(contentsOf: item.children)
            }
        }
        let output = parts.joined(separator: " ")
        func clock(_ hour: Int) -> String {
            (hour < 10 ? "0" : "") + String(hour) + ":"
        }
        return tokens.filter { token in
            if output.contains(token) || output.contains(token.replacingOccurrences(of: ".", with: ":")) { return true }
            // "в 8 вечера" is kept as 20:00, "в 12 ночи" as 00:00.
            guard let hour = Int(token), (1...12).contains(hour) else { return false }
            return output.contains(clock(hour)) || output.contains(clock((hour + 12) % 24)) || (hour == 12 && output.contains("00:"))
        }.count
    }
}
