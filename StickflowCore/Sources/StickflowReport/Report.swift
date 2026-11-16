// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
import StickflowCore

/// `stickflow-report --fixtures <semantic.json> [--models a,b,c] [--host URL]
///     [--phrases <file>] [--machine <text>] [--output <file>] [--limit N]`
///
/// Runs the set that checks structuring by meaning (spec 8.6, 18.3) through the
/// rules, through every named model of an Ollama server and, when the
/// environment has `ANTHROPIC_API_KEY`, through Claude. Writes a report in
/// Markdown: the numbers per provider and every answer in full, because the
/// numbers alone do not choose a model. `scripts/structure-report.sh` wraps it.
@main
enum Report {
    struct SessionNetwork: Network {
        let timeout: TimeInterval

        func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
            var request = request
            request.timeoutInterval = timeout
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    struct Candidate: Sendable {
        let name: String
        /// The Ollama model behind it, to warm up and to unload.
        let ollamaModel: String?
        /// The plan as the structurer gave it, before the cleaning.
        let draft: @Sendable (String) async throws -> NotePlan
    }

    struct Outcome: Sendable {
        var plan: NotePlan?
        var merged = 0
        var seconds = 0.0
        var failure: String?
    }

    static func main() async {
        let arguments = CommandLine.arguments
        func value(_ name: String) -> String? {
            guard let at = arguments.firstIndex(of: name), at + 1 < arguments.count else { return nil }
            return arguments[at + 1]
        }
        guard let fixtures = value("--fixtures") else {
            say("usage: stickflow-report --fixtures <semantic.json> [--models a,b] [--host URL] [--phrases file] [--output file]")
            exit(2)
        }
        do {
            var cases = try JSONDecoder().decode([SemanticCase].self, from: Data(contentsOf: URL(fileURLWithPath: fixtures)))
            if let limit = value("--limit").flatMap({ Int($0) }) { cases = Array(cases.prefix(limit)) }
            let phrases = try value("--phrases").map { try ownPhrases(at: $0) } ?? []
            let host = URL(string: value("--host") ?? "http://127.0.0.1:11434")
            let models = (value("--models") ?? "").split(separator: ",").map(String.init)
            let text = await run(
                cases: cases, phrases: phrases, candidates: candidates(host: host, models: models, claudeModel: value("--claude-model")),
                host: host, machine: value("--machine") ?? "—"
            )
            if let output = value("--output") {
                try text.write(toFile: output, atomically: true, encoding: .utf8)
                say("Отчёт: \(output)")
            } else {
                print(text)
            }
        } catch {
            say("Отчёт не получился: \(error)")
            exit(1)
        }
    }

    /// One phrase per paragraph: blank lines separate them.
    static func ownPhrases(at path: String) throws -> [String] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return text.components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func candidates(host: URL?, models: [String], claudeModel: String?) -> [Candidate] {
        var result = [Candidate(name: "Правила", ollamaModel: nil) { RuleStructurer.plan(from: $0) }]
        // A model's first answer on a laptop may take a minute; nothing here is in a hurry.
        let network = SessionNetwork(timeout: 600)
        if let host {
            for model in models {
                let structurer = ChatStructurer(provider: .ollama(host: host, model: model), network: network)
                result.append(Candidate(name: model, ollamaModel: model) { try await structurer.draft(StructureRequest(text: $0)) })
            }
        }
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            let model = claudeModel ?? ChatProvider.claudeDefaultModel
            let structurer = ChatStructurer(provider: .claude(model: model), network: network, apiKey: { key })
            result.append(Candidate(name: "Claude (\(model))", ollamaModel: nil) { try await structurer.draft(StructureRequest(text: $0)) })
        }
        return result
    }

    static func attempt(_ candidate: Candidate, _ text: String) async -> Outcome {
        var outcome = Outcome()
        let started = Date()
        do {
            let (plan, merged) = try await PlanCleaner.clean(candidate.draft(text))
            outcome.plan = plan
            outcome.merged = merged
        } catch StructurerError.nothingToDo {
            outcome.plan = nil
        } catch let error as StructurerError {
            outcome.failure = "\(error)"
        } catch {
            outcome.failure = error.localizedDescription
        }
        outcome.seconds = Date().timeIntervalSince(started)
        return outcome
    }

    static func run(cases: [SemanticCase], phrases: [String], candidates: [Candidate], host: URL?, machine: String) async -> String {
        var rows: [String] = []
        var answers = [[Outcome]](repeating: [], count: cases.count)
        var own = [[Outcome]](repeating: [], count: phrases.count)
        var failures: [String] = []
        var ran: [Candidate] = []

        for candidate in candidates {
            var warmUp = "—"
            if candidate.ollamaModel != nil {
                say("\(candidate.name): загружаю модель…")
                let first = await attempt(candidate, "Купить хлеб")
                warmUp = seconds(first.seconds)
                if let failure = first.failure {
                    failures.append("\(candidate.name) не запустилась: \(failure)")
                    rows.append("| \(candidate.name) | не запустилась |  |  |  |  |  |  |  | \(warmUp) |  |  |")
                    continue
                }
            }
            ran.append(candidate)
            var score = SemanticScore()
            for (index, semantic) in cases.enumerated() {
                say("\(candidate.name): \(index + 1)/\(cases.count)")
                let outcome = await attempt(candidate, semantic.input)
                answers[index].append(outcome)
                if let failure = outcome.failure { failures.append("\(candidate.name), фраза \(index + 1): \(failure)") }
                // The plan is clean already: its repeats are counted here.
                score.record(semantic, raw: outcome.plan, failed: outcome.failure != nil, seconds: outcome.seconds)
                score.duplicates += outcome.merged
            }
            for (index, phrase) in phrases.enumerated() {
                say("\(candidate.name): своя фраза \(index + 1)/\(phrases.count)")
                await own[index].append(attempt(candidate, phrase))
            }
            rows.append(row(candidate.name, score, warmUp: warmUp))
            if let model = candidate.ollamaModel, let host { await unload(model, host: host) }
        }

        var text = "# Stickflow: отчёт по разбору (ТЗ 8.6, 18.3)\n\n"
        text += "Mac: \(machine)\n\nНабор: \(cases.count) фраз, своих фраз: \(phrases.count).\n\n"
        text += "| Провайдер | Разобрано | Группировка | Найдено пунктов | Лишние | Мусор | Дубли до чистки | Имена и числа "
            + "| Слов в пункте | Прогрев | p50 | p95 |\n|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        text += rows.joined(separator: "\n") + "\n\n"
        text += "Группировка — фразы, где все пункты найдены, пункты одной темы стоят вместе, темы разведены и названы. "
            + "Лишние — пункты, которых никто не говорил. Мусор — пункты с приветствием или словами про саму диктовку. "
            + "Дубли — сколько повторов модель выдала до чистки; в ответах ниже они уже слиты.\n\n"
        if !failures.isEmpty {
            text += "## Сбои\n\n" + failures.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        text += "## Ответы на набор\n\n"
        for (index, semantic) in cases.enumerated() {
            text += "### \(index + 1). \(semantic.input)\n\n"
            for (candidate, outcome) in zip(ran, answers[index]) {
                let verdict = outcome.plan.map { semantic.verdict(for: $0) }
                text += block(candidate.name, outcome, verdict: verdict, scored: semantic.scoresGrouping)
            }
        }
        if !phrases.isEmpty {
            text += "## Свои фразы\n\n"
            for (index, phrase) in phrases.enumerated() {
                text += "### \(index + 1). \(phrase)\n\n"
                for (candidate, outcome) in zip(ran, own[index]) {
                    text += block(candidate.name, outcome, verdict: nil, scored: false)
                }
            }
        }
        return text
    }

    static func row(_ name: String, _ score: SemanticScore, warmUp: String) -> String {
        func share(_ value: Double) -> String { String(format: "%.0f %%", value * 100) }
        return "| \(name) | \(score.answered)/\(score.cases) | \(score.grouped)/\(score.groupingCases) (\(share(score.groupedShare))) "
            + "| \(score.found)/\(score.expected) | \(score.extra) | \(score.junk) | \(score.duplicates) "
            + "| \(score.kept)/\(score.mustKeep) (\(share(score.keptShare))) | \(String(format: "%.1f", score.wordsPerItem)) "
            + "| \(warmUp) | \(seconds(score.latency(percentile: 0.5))) | \(seconds(score.latency(percentile: 0.95))) |"
    }

    static func block(_ name: String, _ outcome: Outcome, verdict: SemanticCase.Verdict?, scored: Bool) -> String {
        var notes = [seconds(outcome.seconds)]
        if let verdict {
            if scored { notes.append(verdict.grouped ? "группы ✓" : "группы ✗") }
            if verdict.found < verdict.expected { notes.append("потеряно \(verdict.expected - verdict.found)") }
            if verdict.extra > 0 { notes.append("лишних \(verdict.extra)") }
            if verdict.junk > 0 { notes.append("мусор \(verdict.junk)") }
        }
        if outcome.merged > 0 { notes.append("дублей \(outcome.merged)") }
        var text = "**\(name)** — \(notes.joined(separator: ", "))\n\n"
        if let failure = outcome.failure {
            text += "Сбой: \(failure)\n\n"
        } else if let plan = outcome.plan, !plan.isEmpty {
            text += "```\n" + plan.previewLines().joined(separator: "\n") + "\n```\n\n"
        } else {
            text += "Задач нет.\n\n"
        }
        return text
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.1f с", value)
    }

    /// Frees the memory before the next model is loaded.
    static func unload(_ model: String, host: URL) async {
        var request = URLRequest(url: host.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0] as [String: Any])
        _ = try? await URLSession.shared.data(for: request)
    }

    static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
