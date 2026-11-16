// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// The first-launch step that brings the speech model to this Mac (spec 18.1):
/// what will be downloaded and how big it is, a button that starts it, the
/// progress. Nothing is downloaded before the button is pressed (spec 0.8).
/// The window may be closed at any time; a download that has started goes on.
@MainActor
final class ModelSetupController: NSObject {
    private let speech: SpeechSetup
    private let preferences: Preferences
    private var window: NSWindow?
    private let view: ModelSetupView

    init(speech: SpeechSetup, preferences: Preferences) {
        self.speech = speech
        self.preferences = preferences
        view = ModelSetupView(megabytes: speech.megabytes)
        super.init()
        view.onPrimary = { [weak self] in self?.primary() }
        view.onSecondary = { [weak self] in self?.window?.close() }
        speech.observe { [weak self] in
            guard let self else { return }
            self.view.state = self.speech.state
        }
    }

    /// Shows the step once, at the first launch without the model.
    func offerIfNeeded() {
        guard speech.state == .missing, !preferences.speechModelOffered else { return }
        preferences.speechModelOffered = true
        preferences.persist()
        show()
    }

    func show() {
        view.state = speech.state
        let window = self.window ?? makeWindow()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let size = NSSize(width: ModelSetupView.width, height: view.preferredHeight)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Stickflow"
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        return window
    }

    private func primary() {
        switch speech.state {
        case .missing, .failed: speech.start()
        case .downloading, .ready, .unsupported: window?.close()
        }
    }
}

/// The content of the step: system type, thin and calm (spec 6.1).
final class ModelSetupView: NSView {
    static let width: CGFloat = 400
    private static let padding: CGFloat = 24

    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?

    var state = SpeechSetup.State.missing {
        didSet { apply() }
    }

    private let megabytes: Int
    private let titleLabel = NSTextField(labelWithString: L10n.setupTitle)
    private let infoLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)

    init(megabytes: Int) {
        self.megabytes = megabytes
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        infoLabel.font = NSFont.systemFont(ofSize: 13)
        infoLabel.stringValue = L10n.setupInfo(megabytes: megabytes)
        infoLabel.isSelectable = false
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = false
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.controlSize = .small
        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        secondaryButton.bezelStyle = .rounded
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryClicked)
        for subview in [titleLabel, infoLabel, progress, statusLabel, secondaryButton, primaryButton] {
            addSubview(subview)
        }
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    @objc private func primaryClicked() {
        onPrimary?()
    }

    @objc private func secondaryClicked() {
        onSecondary?()
    }

    private func apply() {
        var primary = L10n.setupClose
        var secondary: String?
        var showsProgress = false
        switch state {
        case .missing:
            statusLabel.stringValue = L10n.setupLaterNote
            primary = L10n.setupDownload
            secondary = L10n.setupLater
        case let .downloading(percent):
            statusLabel.stringValue = L10n.setupProgress(percent: percent)
            progress.doubleValue = Double(percent)
            showsProgress = true
            primary = L10n.setupHide
        case .ready:
            statusLabel.stringValue = L10n.setupReady
        case .failed:
            statusLabel.stringValue = L10n.setupFailed
            primary = L10n.setupRetry
            secondary = L10n.setupLater
        case .unsupported:
            statusLabel.stringValue = L10n.speechUnsupported
        }
        progress.isHidden = !showsProgress
        primaryButton.title = primary
        secondaryButton.title = secondary ?? ""
        secondaryButton.isHidden = secondary == nil
        needsLayout = true
    }

    private var textWidth: CGFloat { Self.width - Self.padding * 2 }

    private func height(of label: NSTextField) -> CGFloat {
        ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 400)).height ?? 0)
    }

    /// Height of the window's content; the same in every state, so that the window does not jump.
    var preferredHeight: CGFloat {
        Self.padding + 20 + 10 + height(of: infoLabel) + 16 + 8 + 8 + 34 + 20 + 30 + Self.padding - 4
    }

    override func layout() {
        super.layout()
        let padding = Self.padding
        var top = padding
        titleLabel.frame = NSRect(x: padding, y: top, width: textWidth, height: 20)
        top += 20 + 10
        let infoHeight = height(of: infoLabel)
        infoLabel.frame = NSRect(x: padding, y: top, width: textWidth, height: infoHeight)
        top += infoHeight + 16
        progress.frame = NSRect(x: padding, y: top, width: textWidth, height: 8)
        top += 8 + 8
        statusLabel.frame = NSRect(x: padding, y: top, width: textWidth, height: 34)
        let buttonY = bounds.height - padding - 26
        primaryButton.sizeToFit()
        let primaryWidth = max(primaryButton.frame.width, 88)
        primaryButton.frame = NSRect(x: bounds.width - padding - primaryWidth + 4, y: buttonY, width: primaryWidth, height: 30)
        secondaryButton.sizeToFit()
        let secondaryWidth = max(secondaryButton.frame.width, 88)
        secondaryButton.frame = NSRect(x: primaryButton.frame.minX - 6 - secondaryWidth, y: buttonY, width: secondaryWidth, height: 30)
    }
}
