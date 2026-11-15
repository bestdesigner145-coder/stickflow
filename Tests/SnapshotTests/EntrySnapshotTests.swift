// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import SnapshotTesting
@testable import Stickflow
import StickflowCore
import XCTest

/// Pictures of the way in: the pad and the draft (spec 4.2, 4.3).
@MainActor
final class EntrySnapshotTests: XCTestCase {
    private static let themes: [(name: String, appearance: NSAppearance.Name)] = [
        ("light", .aqua),
        ("dark", .darkAqua),
    ]

    func testPad() {
        for theme in Self.themes {
            for hovered in [false, true] {
                let pad = PadView(frame: NSRect(x: 0, y: 0, width: 112, height: 112))
                pad.appearance = NSAppearance(named: theme.appearance)
                pad.paper = .default
                pad.setHoveredForSnapshot(hovered)
                let name = "\(theme.name)-\(hovered ? "hover" : "rest")"
                assertSnapshot(of: SnapshotRenderer.image(of: pad), as: SnapshotRenderer.strategy, named: name)
            }
        }
    }

    func testPadOnTheLeftEdgeFoldsTheOtherCorner() {
        let pad = PadView(frame: NSRect(x: 0, y: 0, width: 112, height: 112))
        pad.appearance = NSAppearance(named: .aqua)
        pad.edge = .left
        assertSnapshot(of: SnapshotRenderer.image(of: pad), as: SnapshotRenderer.strategy)
    }

    /// Out of the edge the pad shows 96 of its 112 pt; the label must still break
    /// between words only, in both languages.
    func testPadLabelBreaksBetweenWords() {
        for (name, label) in [("ru", "Записать задачи"), ("en", "Jot down tasks")] {
            let pad = PadView(frame: NSRect(x: 0, y: 0, width: 112, height: 112))
            pad.appearance = NSAppearance(named: .aqua)
            pad.paper = .default
            pad.label = label
            pad.hiddenWidth = 16
            assertSnapshot(of: SnapshotRenderer.image(of: pad), as: SnapshotRenderer.strategy, named: name)
        }
    }

    func testDraft() {
        for theme in Self.themes {
            for text in ["", "План на день\nДоделать экран кошелька\nСозвон с разработкой в три"] {
                let draft = DraftView(frame: NSRect(x: 0, y: 0, width: 232, height: 160))
                draft.appearance = NSAppearance(named: theme.appearance)
                draft.paper = .default
                draft.textView.string = text
                draft.refresh()
                let height = max(draft.height(fittingWidth: 232), 160)
                draft.frame = NSRect(x: 0, y: 0, width: 232, height: height)
                let name = "\(theme.name)-\(text.isEmpty ? "empty" : "text")"
                assertSnapshot(of: SnapshotRenderer.image(of: draft), as: SnapshotRenderer.strategy, named: name)
            }
        }
    }
}
