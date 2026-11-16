// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// The microphone on a sticker's glue strip (spec 18.4): there while the
/// sticker is being edited and the speech model is on this Mac. What is said
/// is added to the sticker's own lines.
@MainActor
final class StripMicrophone: NSObject {
    enum State {
        case idle
        case recording
        /// Recognising, or taking the text apart.
        case working
    }

    let button = FirstClickButton.symbol("mic", pointSize: 9.5, description: L10n.stickerDictate)
    var onClick: (() -> Void)?
    /// The sticker is no longer being edited.
    var onEditingEnded: (() -> Void)?
    /// Dictation can be used: the model is here and nothing else has the microphone.
    var isAvailable: (() -> Bool)?

    var tint = NSColor.labelColor {
        didSet { apply() }
    }

    var state = State.idle {
        didSet { apply() }
    }

    var isEditing = false {
        didSet {
            guard isEditing != oldValue else { return }
            apply()
            if !isEditing { onEditingEnded?() }
        }
    }

    override init() {
        super.init()
        button.target = self
        button.action = #selector(clicked)
        button.isHidden = true
    }

    @objc private func clicked() {
        onClick?()
    }

    private func apply() {
        // A dictation that is still going keeps its button even after the editing has ended.
        button.isHidden = !((isEditing && (isAvailable?() ?? false)) || state != .idle)
        button.contentTintColor = state == .recording ? .systemRed : tint
        button.alphaValue = state == .working ? 0.4 : 1
        button.isEnabled = state != .working
        button.setAccessibilityLabel(state == .recording ? L10n.stickerStopDictation : L10n.stickerDictate)
    }
}
