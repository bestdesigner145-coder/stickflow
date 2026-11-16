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

    /// The draft while it listens (spec 4.3): recording, the last seconds,
    /// recognising, and a dictation that failed.
    func testDraftDictation() {
        let failure = "Нет доступа к микрофону. Разрешите его: Системные настройки → Конфиденциальность и безопасность → Микрофон."
        let states: [(String, DictationStatus)] = [
            ("recording", DictationStatus(state: .recording, elapsed: 7, level: 0.6)),
            ("ending", DictationStatus(state: .recording, elapsed: 170, level: 0.2, isEnding: true)),
            ("listening", DictationStatus(state: .recognizing)),
            ("error", DictationStatus(message: failure)),
        ]
        for theme in Self.themes {
            for (name, status) in states {
                let draft = DraftView(frame: NSRect(x: 0, y: 0, width: 232, height: 160))
                draft.appearance = NSAppearance(named: theme.appearance)
                draft.paper = .default
                draft.dictation = status
                draft.refresh()
                let height = max(draft.height(fittingWidth: 232), 160)
                draft.frame = NSRect(x: 0, y: 0, width: 232, height: height)
                assertSnapshot(of: SnapshotRenderer.image(of: draft), as: SnapshotRenderer.strategy, named: "\(theme.name)-\(name)")
            }
        }
    }

    /// The draft after Return (spec 4.3): at work, failed, and showing the result;
    /// with the "New / Add to sticker" toggle.
    func testDraftPhases() {
        for theme in Self.themes {
            for phase in ["writing", "structuring", "failed", "result"] {
                let draft = DraftView(frame: NSRect(x: 0, y: 0, width: 232, height: 160))
                draft.appearance = NSAppearance(named: theme.appearance)
                draft.paper = .default
                draft.showsModeToggle = true
                draft.textView.string = "Сначала забрать посылку, потом оплатить интернет"
                switch phase {
                case "writing": draft.modeToggle.isAppend = true
                case "structuring": draft.setPhase(.structuring)
                case "failed": draft.setPhase(.failed)
                default: draft.showResult(lines: ["План на сегодня", "☐ Забрать посылку", "☐ Оплатить интернет"])
                }
                let height = max(draft.height(fittingWidth: 232), 160)
                draft.frame = NSRect(x: 0, y: 0, width: 232, height: height)
                assertSnapshot(of: SnapshotRenderer.image(of: draft), as: SnapshotRenderer.strategy, named: "\(theme.name)-\(phase)")
            }
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
