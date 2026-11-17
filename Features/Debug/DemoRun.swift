// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

#if DEBUG
import AppKit
import StickflowCore

/// `--demo <sound file>`: the first launch played through with the real models,
/// for the video report of spec 17.5a and 18.10. Nothing is faked but the
/// microphone, which plays the file: the window "Voice → tasks", the download,
/// recognition by GigaAM, sorting by the built-in model, the sticker. A line
/// at the top of the screen says what is going on. The result goes to
/// `demo.txt` next to the sound file; the app quits at the end.
@MainActor
enum DemoRun {
    static func run(in environment: AppEnvironment, audio: URL) {
        Task { @MainActor in
            let caption = DemoCaption()
            var log: [String] = []
            func say(_ text: String) {
                caption.show(text)
                log.append("\(Date()) \(text)")
                FileHandle.standardError.write(Data("DEMO \(text)\n".utf8))
            }
            func pause(_ seconds: Double) async {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            func wait(_ limit: Double, until done: () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(limit)
                while Date() < end {
                    if done() { return true }
                    await pause(0.25)
                }
                return done()
            }

            let models = environment.models
            say("Первый запуск: окно «Голос → задачи»")
            environment.showModelSetup()
            await pause(3)
            say("Жму «Скачать»: GigaAM и модель разбора, один раз")
            environment.modelSetup?.pressPrimary()
            let downloaded = await wait(1800) { models.state == .ready || models.state == .failed }
            log.append("models: \(models.state)")
            guard downloaded, models.state == .ready else {
                say("Модели не скачались: \(models.state)")
                return finish(log, audio: audio)
            }
            await pause(2)
            environment.modelSetup?.snapshotView.window?.close()

            say("Черновик у пачки. Жму микрофон и диктую")
            let entry = environment.entry
            entry.toggleDraft()
            await pause(1.5)
            let draft = entry.draft
            draft.dictation.toggle()
            let length = (try? AudioFileReader.read(audio).duration) ?? 20
            await pause(length + 0.5)
            draft.dictation.toggle()
            say("Распознаю речь — GigaAM, на этом Mac")
            let heard = await wait(180) { draft.dictation.state == .idle }
            log.append("heard: \(draft.text)")
            guard heard, !draft.text.isEmpty else {
                say("Речь не распозналась")
                return finish(log, audio: audio)
            }
            await pause(2.5)

            say("Enter: встроенная модель раскладывает по задачам")
            let before = environment.stickers.controllers.count
            draft.submit()
            let stuck = await wait(600) { environment.stickers.controllers.count > before }
            guard stuck, let sticker = environment.stickers.controllers.last else {
                say("Стикер не появился: \(draft.phase)")
                return finish(log, audio: audio)
            }
            await pause(1.5)
            let tasks = sticker.sticker.blocks.filter { $0.kind == .todo }.map(\.text)
            say("Готово: «\(sticker.sticker.title)», задач: \(tasks.count)")
            log.append("title: \(sticker.sticker.title)")
            log += tasks.map { "task: \($0)" }
            await pause(6)
            finish(log, audio: audio)
        }
    }

    private static func finish(_ log: [String], audio: URL) {
        let report = audio.deletingLastPathComponent().appendingPathComponent("demo.txt")
        try? (log.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

/// One line at the top of the screen that says what the video shows.
@MainActor
final class DemoCaption {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        label.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        panel.contentView = label
    }

    func show(_ text: String) {
        label.stringValue = text
        label.sizeToFit()
        guard let screen = NSScreen.main else { return }
        let width = min(label.frame.width + 48, screen.visibleFrame.width - 40)
        let frame = NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.maxY - 64, width: width, height: 44)
        panel.setFrame(frame, display: true)
        label.frame = NSRect(x: 0, y: 8, width: width, height: 28)
        panel.orderFrontRegardless()
    }
}

/// Plays a sound file in place of the microphone, in real time: the level
/// meter moves and the recording is as long as the speech.
final class FileRecorder: VoiceRecorder {
    private let audio: AudioBuffer16k
    private var started: Date?

    init(file: URL) {
        audio = (try? AudioFileReader.read(file)) ?? AudioBuffer16k(samples: [])
    }

    func requestAccess() async -> Bool { true }

    func start() throws {
        started = Date()
    }

    private var played: Int {
        guard let started else { return 0 }
        return min(Int(Date().timeIntervalSince(started) * AudioResampler.speechRate), audio.samples.count)
    }

    func stop() -> AudioBuffer16k {
        let count = played
        started = nil
        return AudioBuffer16k(samples: Array(audio.samples.prefix(count)))
    }

    var level: Float {
        let end = played
        guard started != nil, end > 0 else { return 0 }
        let window = audio.samples[max(0, end - 1600)..<end]
        return min(AudioLevel.rms(Array(window)) * 6, 1)
    }
}
#endif
