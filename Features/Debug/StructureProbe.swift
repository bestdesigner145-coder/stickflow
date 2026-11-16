// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

#if DEBUG
import AppKit
import StickflowCore

/// `Stickflow --structure-report <fixtures.json> [--ollama-host URL] [--models a,b,c]`
///
/// Runs the golden set (spec 8.6) through the rules and through every named
/// model of an Ollama server, and prints the numbers the spec asks for: answers
/// that could be read, task counts that match, names, numbers and times kept,
/// words per item, time per answer. The CI job "llm" runs it on demand; the
/// light model for the app is to be chosen by this report.
enum StructureProbe {
    private struct Fixture: Decodable {
        let input: String
        let plan: NotePlan
    }

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let flag = arguments.firstIndex(of: "--structure-report"), flag + 1 < arguments.count else { return false }
        func value(after name: String) -> String? {
            guard let at = arguments.firstIndex(of: name), at + 1 < arguments.count else { return nil }
            return arguments[at + 1]
        }
        let fixtures = arguments[flag + 1]
        let host = value(after: "--ollama-host") ?? "http://127.0.0.1:11434"
        let models = (value(after: "--models") ?? "").split(separator: ",").map(String.init)
        Task {
            do {
                try await run(fixtures: fixtures, host: host, models: models)
                exit(0)
            } catch {
                say("REPORT FAILED: \(error)")
                exit(1)
            }
        }
        return true
    }

    private static func run(fixtures path: String, host: String, models: [String]) async throws {
        let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let server = URL(string: host) else { throw StructurerError.notConfigured }
        var structurers: [any Structurer] = [RuleStructurer()]
        for model in models {
            // A CI runner has no GPU: an answer may take minutes there.
            structurers.append(ChatStructurer(provider: .ollama(host: server, model: model), network: URLSessionNetwork(timeout: 300)))
        }
        say("GOLDEN SET: \(cases.count) cases")
        for structurer in structurers {
            var score = StructuringScore()
            for (index, fixture) in cases.enumerated() {
                let started = Date()
                var plan: NotePlan?
                var failure = ""
                do {
                    plan = try await structurer.structure(StructureRequest(text: fixture.input)).normalized()
                } catch {
                    failure = "\(error)"
                }
                let seconds = Date().timeIntervalSince(started)
                score.record(input: fixture.input, expected: fixture.plan, plan: plan, seconds: seconds)
                // The spec's own three examples in full, the rest only when they fail.
                if index < 3 || plan == nil {
                    let lines = plan?.previewLines().joined(separator: " | ") ?? "FAILED \(failure)"
                    say(String(format: "SAMPLE %@ #%d [%.1f s]: %@", structurer.displayName, index + 1, seconds, lines))
                }
            }
            say(String(
                format: "REPORT %@: answered %d/%d (%.0f%%), task count %.0f%%, kept %.0f%% (%d/%d), "
                    + "%.1f words/item, p50 %.1f s, p95 %.1f s",
                structurer.displayName, score.answered, score.cases, score.answeredShare * 100, score.countMatchShare * 100,
                score.keptShare * 100, score.kept, score.mustKeep, score.wordsPerItem,
                score.latency(percentile: 0.5), score.latency(percentile: 0.95)
            ))
        }
    }

    private static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
#endif
