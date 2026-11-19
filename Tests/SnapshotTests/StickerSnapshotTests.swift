// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import SnapshotTesting
@testable import Stickflow
import StickflowCore
import XCTest

/// Pictures of the sticker in its states (spec 17.3 and 17.4).
///
/// The references live next to this file in `__Snapshots__`. They are drawn at 1x
/// whatever the display, and were recorded on the macOS 26 CI runner: text is not
/// rendered identically by every macOS version, so CI compares on that runner only.
/// A reference that is missing is recorded and the test fails once; commit the new
/// file. To accept a deliberate change, delete the old reference and run again.
@MainActor
final class StickerSnapshotTests: XCTestCase {
    private enum Theme: String, CaseIterable {
        case light
        case dark
    }

    private static let strategy = SnapshotRenderer.strategy

    func testStickerAtRest() {
        for fixture in [SeedFixture.plan, .long] {
            for theme in Theme.allCases {
                for fontSize in [12.0, 14, 17] {
                    for size in StickerSizeClass.allCases {
                        let image = render(fixture, theme: theme, fontSize: fontSize, size: size)
                        let name = "\(fixture.rawValue)-\(theme.rawValue)-\(Int(fontSize))pt-\(size.rawValue)"
                        assertSnapshot(of: image, as: Self.strategy, named: name)
                    }
                }
            }
        }
    }

    func testPaperColours() {
        for color in PaperColor.allCases {
            for theme in Theme.allCases {
                let image = render(.plan, theme: theme, color: color)
                assertSnapshot(of: image, as: Self.strategy, named: "\(color.rawValue)-\(theme.rawValue)")
            }
        }
    }

    /// With the edit key held over it the sticker is opaque and shows the strip buttons.
    func testStickerInEditMode() {
        for theme in Theme.allCases {
            let image = render(.plan, theme: theme, editKeyHeld: true)
            assertSnapshot(of: image, as: Self.strategy, named: theme.rawValue)
        }
    }

    /// An empty sticker says how to start a heading, a point and a task (spec 18.5).
    func testEmptySticker() {
        MarkupHint.forcedRussianLayout = false
        for theme in Theme.allCases {
            let image = render(.plan, theme: theme, color: .default, isEmpty: true)
            assertSnapshot(of: image, as: Self.strategy, named: theme.rawValue)
        }
    }

    /// While a sticker is edited its glue strip carries a microphone (spec 18.4).
    func testStickerWithMicrophone() {
        for theme in Theme.allCases {
            for recording in [false, true] {
                let image = render(.plan, theme: theme, color: .default, microphone: recording ? .recording : .idle)
                assertSnapshot(of: image, as: Self.strategy, named: "\(theme.rawValue)-\(recording ? "recording" : "idle")")
            }
        }
    }

    // MARK: Rendering

    private func render(
        _ fixture: SeedFixture,
        theme: Theme,
        fontSize: Double = 14,
        size: StickerSizeClass = .medium,
        color: PaperColor = .paper,
        editKeyHeld: Bool = false,
        isEmpty: Bool = false,
        microphone: StripMicrophone.State? = nil
    ) -> NSImage {
        let clock = FixedClock.uiTesting
        let preferences = Preferences(defaults: Self.emptyDefaults())
        preferences.fontSize = fontSize
        preferences.sizeClass = size
        let tuning = Tuning()
        tuning.animationSlowdown = 0

        var sticker = fixture.stickers(now: clock.now)[0]
        sticker.color = color
        if isEmpty {
            sticker.title = ""
            sticker.blocks = []
        }
        let controller = StickerController(sticker: sticker, tuning: tuning, preferences: preferences, clock: clock)
        defer { controller.close() }

        controller.panel.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        controller.applySettings()
        controller.resizeToFit()

        if editKeyHeld {
            // The state machine only listens to a sticker that is on screen.
            controller.show()
            let paper = controller.paperFrame
            controller.pointerDidUpdate(PointerSample(
                location: CGPoint(x: paper.midX, y: paper.midY),
                modifiers: preferences.editKey.flag,
                isMouseDown: false,
                time: 0
            ))
            XCTAssertEqual(controller.mode, .editMode)
        }
        if let microphone {
            controller.rootView.microphone.isAvailable = { true }
            controller.rootView.isEditing = true
            controller.rootView.microphone.state = microphone
        }
        return SnapshotRenderer.image(of: controller.rootView)
    }

    private static func emptyDefaults() -> UserDefaults {
        let name = "io.github.stickflow.snapshot-tests"
        guard let defaults = UserDefaults(suiteName: name) else { return .standard }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
