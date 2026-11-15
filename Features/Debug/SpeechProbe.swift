// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

#if DEBUG
import AppKit
import CoreML
import StickflowCore

/// `Stickflow --transcribe <sound file>… --model-dir <dir> [--cpu-only]`
///
/// Downloads the speech model the way the app does, recognises the files with
/// GigaAM and prints what it heard. CI runs it at night on `main` and on
/// commits marked `[asr]` (spec 17.3): this is the only check of the real model.
enum SpeechProbe {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let flag = arguments.firstIndex(of: "--transcribe") else { return false }
        var files: [String] = []
        var modelDirectory: String?
        var index = flag + 1
        while index < arguments.count {
            if arguments[index] == "--model-dir", index + 1 < arguments.count {
                modelDirectory = arguments[index + 1]
                index += 1
            } else if !arguments[index].hasPrefix("--") {
                files.append(arguments[index])
            }
            index += 1
        }
        let units: MLComputeUnits = arguments.contains("--cpu-only") ? .cpuOnly : .cpuAndGPU
        Task {
            do {
                try await run(files: files, modelDirectory: modelDirectory, units: units)
                exit(0)
            } catch {
                say("PROBE FAILED: \(error)")
                exit(1)
            }
        }
        return true
    }

    private static func run(files: [String], modelDirectory: String?, units: MLComputeUnits) async throws {
        let manifest = try SpeechModelManifest.bundled(named: "gigaam-v3-e2e-rnnt")
        let root = try modelDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? SpeechModelStore.defaultRoot()
        let store = SpeechModelStore(manifest: manifest, root: root)
        let engine = GigaAMEngine(store: store, computeUnits: units)
        say("MODEL \(manifest.id) \(manifest.revision.prefix(12)), \(manifest.totalSize / 1_000_000) MB, installed: \(store.isInstalled)")

        let reporter = ProgressReporter()
        var started = Date()
        try await engine.prepare(progress: { reporter.report($0) })
        say(String(format: "PREPARED in %.1f s", Date().timeIntervalSince(started)))

        for path in files {
            let url = URL(fileURLWithPath: path)
            let audio = try AudioFileReader.read(url)
            started = Date()
            let text = try await engine.transcribe(audio)
            let took = Date().timeIntervalSince(started)
            say(String(format: "TRANSCRIPT %@ [%.1f s of sound, %.2f s]: %@", url.lastPathComponent, audio.duration, took, text))
        }
    }

    private static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Prints the download's progress every tenth.
    private final class ProgressReporter: @unchecked Sendable {
        private let lock = NSLock()
        private var lastTenth = -1

        func report(_ value: Double) {
            let tenth = Int(value * 10)
            lock.lock()
            let isNew = tenth > lastTenth
            if isNew { lastTenth = tenth }
            lock.unlock()
            if isNew { SpeechProbe.say("DOWNLOAD \(tenth * 10)%") }
        }
    }
}
#endif
