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

    /// Small differences in text rendering between machines are not regressions.
    private static let strategy = Snapshotting<NSImage, NSImage>.image(precision: 0.98, perceptualPrecision: 0.98)

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

    // MARK: Rendering

    private func render(
        _ fixture: SeedFixture,
        theme: Theme,
        fontSize: Double = 14,
        size: StickerSizeClass = .medium,
        color: PaperColor = .paper,
        editKeyHeld: Bool = false
    ) -> NSImage {
        let clock = FixedClock.uiTesting
        let preferences = Preferences(defaults: Self.emptyDefaults())
        preferences.fontSize = fontSize
        preferences.sizeClass = size
        let tuning = Tuning()
        tuning.animationSlowdown = 0

        var sticker = fixture.stickers(now: clock.now)[0]
        sticker.color = color
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
        return Self.image(of: controller.rootView)
    }

    private static func emptyDefaults() -> UserDefaults {
        let name = "io.github.stickflow.snapshot-tests"
        guard let defaults = UserDefaults(suiteName: name) else { return .standard }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Draws the view into a bitmap with one pixel per point, so that the picture
    /// has the same size on a Retina display and on a CI runner.
    private static func image(of view: NSView) -> NSImage {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let size = view.bounds.size
        let image = NSImage(size: size)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width.rounded()),
            pixelsHigh: Int(size.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return image }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        image.addRepresentation(bitmap)
        return image
    }
}
