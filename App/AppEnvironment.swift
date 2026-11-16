// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

/// The dependency container: the only place where services are created and
/// wired together (spec 10.1). Everything else receives what it needs.
@MainActor
final class AppEnvironment {
    let options: LaunchOptions
    let tuning: Tuning
    let preferences: Preferences
    let displays: any ScreenGeometry
    let clock: any AppClock
    let loginItem = LoginItemService()
    let hotkeys = HotkeyService()
    let repository: any StickerStore
    let stickers: StickerManager
    /// The call zone, the pad and the draft (stage 2).
    let entry: EntryController
    /// Whether the speech model is on this Mac (spec 18.1).
    let speech: SpeechSetup

    private var modelSetup: ModelSetupController?
    private var statusItem: StatusItemController?
    private var reportedErrors: Set<String> = []
    #if DEBUG
    private var tuningPanel: TuningPanelController?
    #endif

    init(options: LaunchOptions = LaunchOptions(arguments: CommandLine.arguments)) throws {
        self.options = options

        let database: AppDatabase
        let preferences: Preferences
        let displays: any ScreenGeometry
        let clock: any AppClock
        if options.isUITesting {
            // Spec 17.4: every run starts the same and leaves nothing behind.
            // The database and the settings live in memory, the date and the
            // screen layout are fixed, animations are off.
            database = try AppDatabase.inMemory()
            preferences = Preferences(defaults: Self.throwawayDefaults())
            displays = FixedScreenGeometry.single()
            clock = FixedClock.uiTesting
        } else {
            #if DEBUG
            // The CI self-check works on its own database and never touches real stickers.
            let databaseURL = try SelfCheck.prepareDatabaseURL() ?? AppDatabase.defaultURL()
            #else
            let databaseURL = try AppDatabase.defaultURL()
            #endif
            database = try AppDatabase.onDisk(at: databaseURL)
            preferences = Preferences()
            displays = DisplayService()
            clock = SystemClock()
        }

        let repository = StickerRepository(database: database)
        if let seed = options.seed {
            for sticker in seed.stickers(now: clock.now) {
                try repository.save(sticker)
            }
        }
        if let unknownSeed = options.unknownSeed {
            let known = SeedFixture.allCases.map(\.rawValue).joined(separator: ", ")
            FileHandle.standardError.write(Data("Stickflow: unknown --seed=\(unknownSeed). Known: \(known)\n".utf8))
        }

        let tuning = Tuning()
        if options.isUITesting {
            tuning.animationSlowdown = 0
        }
        let pointerSource = SystemPointerSource()
        self.tuning = tuning
        self.preferences = preferences
        self.displays = displays
        self.clock = clock
        self.repository = repository
        let stickers = StickerManager(
            tuning: tuning,
            preferences: preferences,
            repository: repository,
            displays: displays,
            clock: clock,
            pointer: PointerTracker(mouse: pointerSource, modifiers: pointerSource, clock: clock)
        )
        self.stickers = stickers
        // Tests and the self-check have no microphone: they get a scripted one.
        let isScripted = options.isUITesting || options.selfCheckDirectory != nil
        let recorder: any VoiceRecorder = isScripted ? ScriptedRecorder() : MicrophoneRecorder()
        // A run that must look the same everywhere does not ask which layout is on.
        if isScripted { MarkupHint.forcedRussianLayout = false }
        let engine: any SpeechEngine
        let speech: SpeechSetup
        if isScripted {
            engine = ScriptedSpeechEngine()
            speech = .ready()
        } else {
            let made = Self.makeSpeech(idleUnload: tuning.speechModelIdleUnload)
            engine = made.engine
            speech = made.setup
        }
        self.speech = speech
        entry = EntryController(
            tuning: tuning,
            preferences: preferences,
            displays: displays,
            stickers: stickers,
            // Tests and the self-check never touch the network: the rules only.
            makeStructurer: { [preferences] in
                if isScripted { return RuleStructurer() }
                return StructurerFactory.make(from: preferences, network: URLSessionNetwork())
            },
            dictation: Dictation(recorder: recorder, engine: engine, tuning: tuning),
            // The same microphone and model, for dictation into a sticker (spec 18.4).
            stickerDictation: Dictation(recorder: recorder, engine: engine, tuning: tuning),
            speech: speech,
            clock: clock
        )
    }

    /// Settings that start empty and are never written to disk.
    /// Spec 7, 18.1: Russian, recognised on this Mac by GigaAM and by nothing
    /// else. Until its model is here there is no dictation; on macOS 14 there is none at all.
    private static func makeSpeech(idleUnload: TimeInterval) -> (engine: any SpeechEngine, setup: SpeechSetup) {
        guard let manifest = try? SpeechModelManifest.bundled(named: "gigaam-v3-e2e-rnnt"),
              let root = try? SpeechModelStore.defaultRoot() else {
            return (NoSpeechEngine(), SpeechSetup(isSupported: false, isInstalled: false, megabytes: 0) { _ in })
        }
        let store = SpeechModelStore(manifest: manifest, root: root)
        let engine = GigaAMEngine(store: store, idleUnload: idleUnload)
        let megabytes = Int(manifest.totalSize / 1_000_000)
        let setup = SpeechSetup(isSupported: engine.isSupported, isInstalled: store.isInstalled, megabytes: megabytes) { progress in
            try await engine.prepare(progress: progress)
        }
        return (engine, setup)
    }

    private static func throwawayDefaults() -> UserDefaults {
        let name = "io.github.stickflow.ui-testing"
        guard let defaults = UserDefaults(suiteName: name) else { return .standard }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func start() {
        stickers.onError = { [weak self] title, error in
            self?.report(title: title, error: error)
        }
        stickers.onUndoShortcutArmedChange = { [weak self] armed in
            self?.hotkeys.setUndoPeelArmed(armed)
        }
        stickers.onPointerSample = { [weak self] sample in
            self?.entry.pointerDidUpdate(sample)
        }
        stickers.alsoNeedsPolling = { [weak self] location in
            self?.entry.needsPointer(at: location) ?? false
        }
        stickers.peelTarget = { [weak self] in
            self?.entry.padPoint
        }
        stickers.onCaptureHidingChange = { [weak self] hidden in
            self?.entry.setSuppressed(hidden)
        }
        stickers.start()
        entry.start()
        hotkeys.start(
            onQuickInput: { [weak self] in
                self?.entry.toggleDraft()
            },
            onToggleStickers: { [weak self] in
                self?.stickers.toggleStickersHidden()
            },
            onUndoPeel: { [weak self] in
                self?.stickers.undoLastPeel()
            }
        )
        statusItem = StatusItemController(environment: self)
        // Spec 18.1: the speech model is offered once, at the first launch.
        let modelSetup = ModelSetupController(speech: speech, preferences: preferences)
        self.modelSetup = modelSetup
        modelSetup.offerIfNeeded()
    }

    // MARK: Debug panel

    #if DEBUG
    func showTuningPanel() {
        if tuningPanel == nil {
            tuningPanel = TuningPanelController(environment: self)
        }
        tuningPanel?.show()
    }
    #endif

    // MARK: Errors

    /// Shows each kind of error once per launch; repeating it on every key press helps nobody.
    func report(title: String, error: Error) {
        guard reportedErrors.insert(title).inserted else { return }
        Self.presentAlert(title: title, error: error)
    }

    static func presentAlert(title: String, error: Error) {
        #if DEBUG
        if SelfCheck.isActive {
            // A modal alert would hang an unattended run.
            print("ALERT  \(title): \(error)")
            exit(2)
        }
        #endif
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}
