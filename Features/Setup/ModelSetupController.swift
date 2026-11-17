// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit

/// The first-launch window "Voice → tasks" (spec 18.10 A3): what will be
/// downloaded and how big it is, a button that starts it, the progress.
/// Nothing is downloaded before the button is pressed (spec 0.8). The window
/// may be closed at any time; a download that has started goes on.
@MainActor
final class ModelSetupController: NSObject {
    private let models: ModelsSetup
    private var window: NSWindow?
    private let view: ModelSetupView

    init(models: ModelsSetup) {
        self.models = models
        view = ModelSetupView()
        super.init()
        view.onPrimary = { [weak self] in self?.primary() }
        view.onSecondary = { [weak self] in self?.window?.close() }
        models.observe { [weak self] in self?.refresh() }
    }

    /// Shown at launch for as long as a model is missing (spec 18.10 E5).
    func offerIfNeeded() {
        guard models.state == .missing || models.state == .failed else { return }
        show()
    }

    func show() {
        refresh()
        let window = self.window ?? makeWindow()
        self.window = window
        window.setContentSize(NSSize(width: ModelSetupView.width, height: view.preferredHeight))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func refresh() {
        view.content = ModelSetupView.Content(models: models)
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
        switch models.state {
        case .missing, .failed: models.start()
        case .downloading, .ready: window?.close()
        }
    }

    #if DEBUG
    /// For the self-check.
    var isShown: Bool { window?.isVisible ?? false }
    var snapshotView: NSView { view }
    func pressPrimary() {
        primary()
    }
    #endif
}

/// The content of the window: system type, calm (spec 6.1); the texts of spec 18.10 A3 word for word.
final class ModelSetupView: NSView {
    static let width: CGFloat = 420
    private static let padding: CGFloat = 24

    /// What the window says.
    enum Stage: Equatable {
        case offer
        case downloading(received: Int64, total: Int64)
        case ready
        case failed
    }

    struct Content: Equatable {
        var stage: Stage
        var total: Int64

        init(stage: Stage, total: Int64) {
            self.stage = stage
            self.total = total
        }

        @MainActor
        init(models: ModelsSetup) {
            total = models.totalBytes
            switch models.state {
            case .missing: stage = .offer
            case let .downloading(received, total): stage = .downloading(received: received, total: total)
            case .ready: stage = .ready
            case .failed: stage = .failed
            }
        }
    }

    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?

    var content = Content(stage: .offer, total: 3_000_000_000) {
        didSet {
            if content != oldValue { apply() }
        }
    }

    private let titleLabel = NSTextField(labelWithString: L10n.setupTitle)
    private let infoLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        infoLabel.font = NSFont.systemFont(ofSize: 13)
        infoLabel.isSelectable = false
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = false
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        primaryButton.bezelStyle = .push
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        secondaryButton.bezelStyle = .push
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryClicked)
        for subview in [titleLabel, infoLabel, progress, statusLabel, secondaryButton, primaryButton] {
            addSubview(subview)
        }
        apply()
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
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

    /// "1,2" and "3": gigabytes the way people say them.
    static func gigabytes(_ bytes: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: (Double(bytes) / 1e9 * 10).rounded() / 10)) ?? "0"
    }

    private func apply() {
        infoLabel.stringValue = L10n.setupInfo(gigabytes: Self.gigabytes(content.total))
        var primary = L10n.setupClose
        var secondary: String?
        var shown: Double?
        switch content.stage {
        case .offer:
            statusLabel.stringValue = ""
            primary = L10n.setupDownload
            secondary = L10n.setupLater
        case let .downloading(received, total):
            statusLabel.stringValue = L10n.setupProgress(received: Self.gigabytes(received), total: Self.gigabytes(total))
            shown = total > 0 ? Double(received) / Double(total) : 0
            primary = L10n.setupHide
        case .ready:
            statusLabel.stringValue = L10n.setupReady
        case .failed:
            statusLabel.stringValue = L10n.setupFailed
            primary = L10n.setupRetry
            secondary = L10n.setupLater
        }
        progress.isHidden = shown == nil
        progress.doubleValue = shown ?? 0
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
        Self.padding + 22 + 10 + height(of: infoLabel) + 18 + 8 + 8 + 34 + 16 + 30 + Self.padding
    }

    override func layout() {
        super.layout()
        let padding = Self.padding
        var top = padding
        titleLabel.frame = NSRect(x: padding, y: top, width: textWidth, height: 22)
        top += 22 + 10
        let infoHeight = height(of: infoLabel)
        infoLabel.frame = NSRect(x: padding, y: top, width: textWidth, height: infoHeight)
        top += infoHeight + 18
        progress.frame = NSRect(x: padding, y: top, width: textWidth, height: 8)
        top += 8 + 8
        statusLabel.frame = NSRect(x: padding, y: top, width: textWidth, height: 34)
        let buttonY = bounds.height - padding - 28
        primaryButton.sizeToFit()
        let primaryWidth = max(primaryButton.frame.width + 12, 96)
        primaryButton.frame = NSRect(x: bounds.width - padding - primaryWidth + 6, y: buttonY, width: primaryWidth, height: 30)
        secondaryButton.sizeToFit()
        let secondaryWidth = max(secondaryButton.frame.width + 12, 96)
        secondaryButton.frame = NSRect(x: primaryButton.frame.minX - 4 - secondaryWidth, y: buttonY, width: secondaryWidth, height: 30)
    }
}
