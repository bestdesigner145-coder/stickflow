// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import CoreML
import LocalModel
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
    /// Whether the two models are on this Mac (spec 18.1, 18.10).
    let models: ModelsSetup
    /// The model that takes dictation apart (spec 18.10).
    let builtIn: BuiltInModel

    private(set) var modelSetup: ModelSetupController?
    private var settingsWindow: SettingsWindowController?
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
        if options.isUITesting || options.demoAudio != nil {
            // Spec 17.4: every run starts the same and leaves nothing behind.
            // The database and the settings live in memory, the date and the
            // screen layout are fixed, animations are off.
            database = try AppDatabase.inMemory()
            preferences = Preferences(defaults: Self.throwawayDefaults())
            displays = options.isUITesting ? FixedScreenGeometry.single() : DisplayService()
            clock = options.isUITesting ? FixedClock.uiTesting : SystemClock()
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
        let recorder = Self.makeRecorder(options: options, isScripted: isScripted)
        // A run that must look the same everywhere does not ask which layout is on.
        if isScripted { MarkupHint.forcedRussianLayout = false }
        var llama = LlamaSettings()
        llama.idleUnload = tuning.structuringModelIdleUnload
        if options.isCPUOnly { llama.gpuLayers = 0 }
        let root = options.modelsRoot.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? (try? ModelStore.defaultRoot())
        let builtIn = BuiltInModel(root: isScripted ? nil : root, settings: llama)
        self.builtIn = builtIn
        let engine: any SpeechEngine
        let models: ModelsSetup
        if isScripted {
            engine = ScriptedSpeechEngine()
            models = .ready()
        } else {
            let made = Self.makeSpeech(root: root, idleUnload: tuning.speechModelIdleUnload, cpuOnly: options.isCPUOnly)
            engine = made.engine
            models = ModelsSetup(speech: made.model, structuring: builtIn.model)
        }
        self.models = models
        // The built-in model, or what stands in for it while it is on its way.
        let makeBuiltIn: () -> any Structurer = { [builtIn, models] in
            if isScripted { return RuleStructurer() }
            return BuiltInStructurer(model: builtIn.local, percent: models.structuringPercent)
        }
        entry = EntryController(
            tuning: tuning,
            preferences: preferences,
            displays: displays,
            stickers: stickers,
            // Tests and the self-check never touch the network: the rules only.
            makeStructurer: { [preferences] in
                if isScripted { return RuleStructurer() }
                return StructurerFactory.make(from: preferences, network: URLSessionNetwork(), builtIn: makeBuiltIn())
            },
            makeBuiltIn: makeBuiltIn,
            primeBuiltIn: { [builtIn] in builtIn.prime() },
            dictation: Dictation(recorder: recorder, engine: engine, tuning: tuning),
            // The same microphone and model, for dictation into a sticker (spec 18.4).
            stickerDictation: Dictation(recorder: recorder, engine: engine, tuning: tuning),
            models: models,
            clock: clock
        )
    }

    /// Settings that start empty and are never written to disk.
    /// Spec 7, 18.1: Russian, recognised on this Mac by GigaAM and by nothing
    /// else. Until its model is here there is no dictation; on macOS 14 there is none at all.
    private static func makeSpeech(
        root: URL?, idleUnload: TimeInterval, cpuOnly: Bool
    ) -> (engine: any SpeechEngine, model: ModelsSetup.Model) {
        guard let manifest = try? ModelManifest.bundled(named: "gigaam-v3-e2e-rnnt"), let root else {
            return (NoSpeechEngine(), .none)
        }
        let store = ModelStore(manifest: manifest, root: root)
        let engine = GigaAMEngine(store: store, computeUnits: cpuOnly ? .cpuOnly : .cpuAndGPU, idleUnload: idleUnload)
        let model = ModelsSetup.Model(
            size: manifest.totalSize,
            isSupported: engine.isSupported,
            isInstalled: { store.isInstalled },
            bytesInPlace: { store.bytesInPlace },
            install: { progress in try await store.install(progress: progress) },
            remove: { store.remove() }
        )
        return (engine, model)
    }

    /// The settings window: "Sorting" for now (spec 18.10 C1).
    func showSettings() {
        if settingsWindow == nil {
            let model = StructuringSettingsModel(
                preferences: preferences, models: models, network: URLSessionNetwork(timeout: 15), builtInName: builtIn.name
            )
            settingsWindow = SettingsWindowController(model: model)
        }
        settingsWindow?.show()
    }

    /// The window "Voice → tasks" (spec 18.10 A3).
    private static func makeRecorder(options: LaunchOptions, isScripted: Bool) -> any VoiceRecorder {
        #if DEBUG
        // The video report plays a sound file in place of the microphone.
        if let audio = options.demoAudio { return FileRecorder(file: URL(fileURLWithPath: audio)) }
        #endif
        return isScripted ? ScriptedRecorder() : MicrophoneRecorder()
    }

    func showModelSetup() {
        modelSetup?.show()
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
        // Spec 18.10 A3, E5: the models are offered at launch for as long as one is missing.
        let modelSetup = ModelSetupController(models: models)
        self.modelSetup = modelSetup
        if !(options.isUITesting || options.selfCheckDirectory != nil || options.demoAudio != nil) { modelSetup.offerIfNeeded() }
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
