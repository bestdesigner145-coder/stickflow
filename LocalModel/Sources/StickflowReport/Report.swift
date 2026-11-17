// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
import LocalModel
import StickflowCore

/// `stickflow-report --fixtures <semantic.json> [--local name=model.gguf]…
///     [--models a,b --host URL] [--phrases file] [--machine text]
///     [--output report.md] [--json summary.json] [--limit N]`
///
/// Runs the set that checks structuring by meaning (spec 8.6, 18.3, 18.10 A5)
/// through the rules, through models run inside the process by llama.cpp,
/// through an Ollama server and, when the environment has `ANTHROPIC_API_KEY`,
/// through Claude. Writes the numbers per provider and every answer in full,
/// because the numbers alone do not choose a model. CI runs it on every
/// candidate; `scripts/combine-reports.py` puts the summaries side by side.
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
        /// Size of the model file, for the table; 0 when there is no file.
        let bytes: Int64
        /// Loads the model and reads the prompt's fixed part once, before the clock starts.
        let warmUp: (@Sendable () async throws -> Void)?
        let unload: (@Sendable () async -> Void)?
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
        func values(_ name: String) -> [String] {
            arguments.indices.filter { arguments[$0] == name && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
        }
        guard let fixtures = value("--fixtures") else {
            say("usage: stickflow-report --fixtures <semantic.json> [--local name=file.gguf] [--output file] [--json file]")
            exit(2)
        }
        do {
            var cases = try JSONDecoder().decode([SemanticCase].self, from: Data(contentsOf: URL(fileURLWithPath: fixtures)))
            if let limit = value("--limit").flatMap({ Int($0) }) { cases = Array(cases.prefix(limit)) }
            let phrases = try value("--phrases").map { try ownPhrases(at: $0) } ?? []
            var candidates = [rules()]
            candidates += values("--local").compactMap(local)
            if let host = URL(string: value("--host") ?? "http://127.0.0.1:11434") {
                let models = (value("--models") ?? "").split(separator: ",").map(String.init)
                candidates += models.map { ollama($0, host: host) }
            }
            if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
                candidates.append(claude(key: key, model: value("--claude-model")))
            }
            if arguments.contains("--no-rules") { candidates.removeFirst() }
            let (text, summary) = await run(cases: cases, phrases: phrases, candidates: candidates, machine: value("--machine") ?? "—")
            if let output = value("--output") {
                try text.write(toFile: output, atomically: true, encoding: .utf8)
                say("Отчёт: \(output)")
            } else {
                print(text)
            }
            if let json = value("--json") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(summary).write(to: URL(fileURLWithPath: json))
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

    // MARK: Candidates

    static func rules() -> Candidate {
        Candidate(name: "Правила", bytes: 0, warmUp: nil, unload: nil) { RuleStructurer.plan(from: $0) }
    }

    /// `name=path`: a GGUF file run inside this process, as the app runs it.
    static func local(_ argument: String) -> Candidate? {
        let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let file = URL(fileURLWithPath: parts[1])
        var settings = LlamaSettings()
        if let layers = ProcessInfo.processInfo.environment["STICKFLOW_GPU_LAYERS"].flatMap({ Int32($0) }) {
            settings.gpuLayers = layers
        }
        let runner = LlamaRunner(file: file, settings: settings)
        let structurer = LocalStructurer(runner: runner, displayName: parts[0])
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        return Candidate(
            name: parts[0], bytes: bytes,
            warmUp: { _ = try? await structurer.draft(StructureRequest(text: "Купить хлеб")) },
            unload: { runner.unload() },
            draft: { try await structurer.draft(StructureRequest(text: $0)).plan }
        )
    }

    static func ollama(_ model: String, host: URL) -> Candidate {
        let structurer = ChatStructurer(provider: .ollama(host: host, model: model), network: SessionNetwork(timeout: 600))
        return Candidate(
            name: model, bytes: 0,
            warmUp: { _ = try? await structurer.draft(StructureRequest(text: "Купить хлеб")) },
            unload: { await unload(model, host: host) },
            draft: { try await structurer.draft(StructureRequest(text: $0)) }
        )
    }

    static func claude(key: String, model: String?) -> Candidate {
        let name = model ?? ChatProvider.claudeDefaultModel
        let structurer = ChatStructurer(provider: .claude(model: name), network: SessionNetwork(timeout: 120), apiKey: { key })
        return Candidate(name: "Claude (\(name))", bytes: 0, warmUp: nil, unload: nil) {
            try await structurer.draft(StructureRequest(text: $0))
        }
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
        } catch {
            outcome.failure = "\(error)"
        }
        outcome.seconds = Date().timeIntervalSince(started)
        return outcome
    }

    // MARK: Running

    /// The numbers of one candidate, for the table across all candidates.
    struct Summary: Codable, Sendable {
        var name: String
        var bytes: Int64
        var warmUp: Double
        var cases: Int
        var answered: Int
        var grouped: Int
        var groupingCases: Int
        var found: Int
        var expected: Int
        var extra: Int
        var junk: Int
        var duplicates: Int
        var kept: Int
        var mustKeep: Int
        var titled: Int
        var titleCases: Int
        var wordsPerItem: Double
        var p50: Double
        var p95: Double
        /// The two regressions of spec 18.9 B3: grouping, title, no junk.
        var regressions: [String: Bool]
        var failures: Int
    }

    static func run(cases: [SemanticCase], phrases: [String], candidates: [Candidate], machine: String) async -> (String, [Summary]) {
        var summaries: [Summary] = []
        var answers = [[Outcome]](repeating: [], count: cases.count)
        var own = [[Outcome]](repeating: [], count: phrases.count)
        var failures: [String] = []

        for candidate in candidates {
            var warmUp = 0.0
            if let prepare = candidate.warmUp {
                say("\(candidate.name): загружаю модель…")
                let started = Date()
                try? await prepare()
                warmUp = Date().timeIntervalSince(started)
            }
            var score = SemanticScore()
            var regressions: [String: Bool] = [:]
            var failed = 0
            for (index, semantic) in cases.enumerated() {
                let outcome = await attempt(candidate, semantic.input)
                say("\(candidate.name): \(index + 1)/\(cases.count), \(seconds(outcome.seconds))\(outcome.failure.map { " — \($0)" } ?? "")")
                answers[index].append(outcome)
                if let failure = outcome.failure {
                    failures.append("\(candidate.name), фраза \(index + 1): \(failure)")
                    failed += 1
                }
                score.record(semantic, raw: outcome.plan, failed: outcome.failure != nil, seconds: outcome.seconds)
                score.duplicates += outcome.merged
                if semantic.inPrompt {
                    let verdict = outcome.plan.map { semantic.verdict(for: $0) }
                    let passed = verdict.map { $0.grouped && $0.titled != false && $0.junk == 0 } ?? false
                    regressions[String(semantic.input.prefix(40))] = passed
                }
            }
            for (index, phrase) in phrases.enumerated() {
                await own[index].append(attempt(candidate, phrase))
            }
            if let unload = candidate.unload { await unload() }
            summaries.append(Summary(
                name: candidate.name, bytes: candidate.bytes, warmUp: warmUp, cases: score.cases, answered: score.answered,
                grouped: score.grouped, groupingCases: score.groupingCases, found: score.found, expected: score.expected,
                extra: score.extra, junk: score.junk, duplicates: score.duplicates, kept: score.kept, mustKeep: score.mustKeep,
                titled: score.titled, titleCases: score.titleCases, wordsPerItem: score.wordsPerItem,
                p50: score.latency(percentile: 0.5), p95: score.latency(percentile: 0.95), regressions: regressions, failures: failed
            ))
        }
        return (document(cases: cases, phrases: phrases, names: candidates.map(\.name), summaries: summaries,
                         answers: answers, own: own, failures: failures, machine: machine), summaries)
    }

    // swiftlint:disable:next function_parameter_count
    static func document(
        cases: [SemanticCase], phrases: [String], names: [String], summaries: [Summary],
        answers: [[Outcome]], own: [[Outcome]], failures: [String], machine: String
    ) -> String {
        var text = "# Stickflow: отчёт по разбору (ТЗ 8.6, 18.10)\n\n"
        text += "Машина: \(machine)\n\nНабор: \(cases.count) фраз, из них в примерах промпта: \(cases.filter(\.inPrompt).count). "
            + "Своих фраз: \(phrases.count).\n\n"
        text += table(summaries) + "\n"
        text += "Группировка — все пункты найдены, стоят по порядку, где он важен, темы разведены и названы. "
            + "Лишние — пункты, которых не говорили. Мусор — приветствия, описания, слова про саму диктовку. "
            + "Дубли — повторы в ответе до чистки. B3 — две диктовки автора (они же есть в примерах промпта).\n\n"
        if !failures.isEmpty {
            text += "## Сбои\n\n" + failures.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        text += "## Ответы на набор\n\n"
        for (index, semantic) in cases.enumerated() {
            let seen = semantic.inPrompt ? " _(есть в примерах)_" : ""
            text += "### \(index + 1). \(semantic.input)\(seen)\n\n"
            for (name, outcome) in zip(names, answers[index]) {
                let verdict = outcome.plan.map { semantic.verdict(for: $0) }
                text += block(name, outcome, verdict: verdict, scored: semantic.scoresGrouping)
            }
        }
        if !phrases.isEmpty {
            text += "## Свои фразы\n\n"
            for (index, phrase) in phrases.enumerated() {
                text += "### \(index + 1). \(phrase)\n\n"
                for (name, outcome) in zip(names, own[index]) {
                    text += block(name, outcome, verdict: nil, scored: false)
                }
            }
        }
        return text
    }

    static func table(_ summaries: [Summary]) -> String {
        func share(_ part: Int, _ whole: Int) -> String {
            whole == 0 ? "—" : "\(part)/\(whole)"
        }
        var text = "| Провайдер | Размер | JSON | Группировка | Заголовок | Найдено | Лишние | Мусор | Дубли | Имена и числа "
            + "| B3 | Прогрев | p50 | p95 |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for summary in summaries {
            let size = summary.bytes > 0 ? String(format: "%.1f ГБ", Double(summary.bytes) / 1e9) : "—"
            let regressions = summary.regressions.values.filter { $0 }.count
            text += "| \(summary.name) | \(size) | \(share(summary.answered, summary.cases)) "
                + "| \(share(summary.grouped, summary.groupingCases)) | \(share(summary.titled, summary.titleCases)) "
                + "| \(share(summary.found, summary.expected)) | \(summary.extra) | \(summary.junk) | \(summary.duplicates) "
                + "| \(share(summary.kept, summary.mustKeep)) | \(regressions)/\(summary.regressions.count) "
                + "| \(seconds(summary.warmUp)) | \(seconds(summary.p50)) | \(seconds(summary.p95)) |\n"
        }
        return text
    }

    static func block(_ name: String, _ outcome: Outcome, verdict: SemanticCase.Verdict?, scored: Bool) -> String {
        var notes = [seconds(outcome.seconds)]
        if let verdict {
            if scored { notes.append(verdict.grouped ? "группы ✓" : "группы ✗") }
            if let titled = verdict.titled { notes.append(titled ? "заголовок ✓" : "заголовок ✗") }
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
