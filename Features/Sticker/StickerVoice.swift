// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

/// Dictation into a sticker that is already on screen (spec 18.4): the
/// microphone on its glue strip records, the speech is recognised and taken
/// apart, and the new lines join the sticker's own, nothing twice.
@MainActor
final class StickerVoice {
    private let dictation: Dictation
    private let stickers: StickerManager
    private let models: ModelsSetup
    /// Takes dictated text apart; `nil` when there is nothing to make of it.
    private let makePlan: @MainActor (String) async -> NotePlan?
    private weak var target: StickerController?
    private var work: Task<Void, Never>?
    /// True while the draft has the microphone.
    var isBlocked: () -> Bool = { false }
    /// A model's reading of what was said into a sticker (spec 18.22); `nil` — no model, append.
    var makeEdit: @MainActor (StickerEditRequest) async -> Result<StickerEdit, any Error>? = { _ in nil }
    /// The provider's name, for "No Claude key".
    var providerName: () -> String = { "" }

    init(dictation: Dictation, stickers: StickerManager, models: ModelsSetup, makePlan: @escaping @MainActor (String) async -> NotePlan?) {
        self.dictation = dictation
        self.stickers = stickers
        self.models = models
        self.makePlan = makePlan
        dictation.onChange = { [weak self] in self?.show() }
        dictation.onText = { [weak self] text in self?.add(text) }
        stickers.onControllerCreated = { [weak self] controller in self?.attach(to: controller) }
    }

    var isBusy: Bool { dictation.isBusy || work != nil }

    private func attach(to controller: StickerController) {
        let microphone = controller.rootView.microphone
        microphone.isAvailable = { [weak self] in
            guard let self else { return false }
            return self.models.isSpeechReady && !self.isBlocked()
        }
        microphone.onClick = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.toggle(for: controller)
        }
        microphone.onEditingEnded = { [weak self, weak controller] in
            guard let self, let controller, self.target === controller else { return }
            // Whatever has been said so far still goes into the sticker.
            if self.dictation.state == .recording { self.dictation.toggle() }
        }
    }

    /// The microphone on `controller`'s strip was pressed.
    func toggle(for controller: StickerController) {
        if let target, target !== controller { cancel() }
        guard models.isSpeechReady, !isBlocked(), work == nil else { return }
        target = controller
        dictation.toggle()
    }

    /// The draft is opening, or the sticker is going away: drop everything.
    func cancel() {
        work?.cancel()
        work = nil
        dictation.cancel()
        target?.rootView.microphone.state = .idle
        target = nil
    }

    private func show() {
        guard let target else { return }
        let state: StripMicrophone.State
        if work != nil {
            state = .working
        } else {
            switch dictation.state {
            case .idle: state = .idle
            case .recording: state = .recording
            case .preparing, .recognizing: state = .working
            }
        }
        target.rootView.microphone.state = state
    }

    private func add(_ text: String) {
        guard let controller = target else { return }
        let makePlan = self.makePlan
        let makeEdit = self.makeEdit
        let request = StickerEditRequest(title: controller.sticker.title, blocks: controller.sticker.blocks, text: text)
        work = Task { [weak self] in
            // A model reads commands ("отметь созвон") as well as new thoughts (spec 18.22).
            if let edited = await makeEdit(request) {
                guard let self, !Task.isCancelled else { return }
                self.work = nil
                if !controller.isClosed { self.apply(edited, said: text, to: controller) }
                self.show()
                return
            }
            let plan = await makePlan(text)
            guard let self, !Task.isCancelled else { return }
            self.work = nil
            // Text nothing could be made of is added as one line, as it was said.
            let lines = plan ?? NotePlan(title: "", sections: [NotePlan.Section(items: [NotePlan.Item(text: text)])])
            if !controller.isClosed {
                self.stickers.append(lines, to: controller)
            }
            self.show()
        }
        show()
    }

    private func apply(_ edited: Result<StickerEdit, any Error>, said text: String, to controller: StickerController) {
        switch edited {
        case let .success(edit):
            do {
                let result = try edit.apply(title: controller.sticker.title, to: controller.sticker.blocks)
                stickers.applyEdit(result, to: controller)
            } catch StickerEdit.Failure.unclearLine {
                stickers.note(L10n.voiceUnclearLine, under: controller)
            } catch {
                // Nothing changed: what was said is not lost.
                stickers.append(Self.asSaid(text), to: controller)
            }
        case let .failure(error):
            // What was said stays in the sticker; the note says why it was not understood.
            stickers.append(Self.asSaid(text), to: controller)
            if let error = error as? StructurerError, let reason = L10n.stickerEditFailure(error, provider: providerName()) {
                stickers.note(reason, under: controller)
            }
        }
    }

    private static func asSaid(_ text: String) -> NotePlan {
        NotePlan(title: "", sections: [NotePlan.Section(items: [NotePlan.Item(text: text)])])
    }
}
