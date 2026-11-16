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

    override func setUp() async throws {
        // The line about headings and tasks depends on the keyboard layout.
        MarkupHint.forcedRussianLayout = false
    }

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

    /// The oval behind the pad: no edge to be seen (stage 3 review, H5).
    func testPadGlow() {
        for theme in Self.themes {
            let glow = PadGlowView(frame: NSRect(x: 0, y: 0, width: 140, height: 200))
            glow.appearance = NSAppearance(named: theme.appearance)
            assertSnapshot(of: SnapshotRenderer.image(of: glow), as: SnapshotRenderer.strategy, named: theme.name)
        }
    }

    /// In the microphone's place until the speech model is on this Mac (spec 18.1).
    func testDraftWithoutTheSpeechModel() {
        let states: [(String, SpeechSetup.State)] = [
            ("downloading", .downloading(42)), ("missing", .missing), ("failed", .failed), ("unsupported", .unsupported),
        ]
        MarkupHint.forcedRussianLayout = false
        for theme in Self.themes {
            for (name, state) in states {
                let draft = DraftView(frame: NSRect(x: 0, y: 0, width: 232, height: 160))
                draft.appearance = NSAppearance(named: theme.appearance)
                draft.paper = .default
                draft.speechMegabytes = 445
                draft.speech = state
                draft.refresh()
                let height = max(draft.height(fittingWidth: 232), 160)
                draft.frame = NSRect(x: 0, y: 0, width: 232, height: height)
                assertSnapshot(of: SnapshotRenderer.image(of: draft), as: SnapshotRenderer.strategy, named: "\(theme.name)-\(name)")
            }
        }
    }

    /// The first-launch step that brings the speech model (spec 18.1).
    func testModelSetup() {
        let states: [(String, SpeechSetup.State)] = [
            ("offer", .missing), ("downloading", .downloading(42)), ("ready", .ready), ("failed", .failed),
        ]
        for theme in Self.themes {
            for (name, state) in states {
                let view = ModelSetupView(megabytes: 445)
                view.appearance = NSAppearance(named: theme.appearance)
                view.state = state
                view.frame = NSRect(x: 0, y: 0, width: ModelSetupView.width, height: view.preferredHeight)
                assertSnapshot(of: SnapshotRenderer.image(of: view), as: SnapshotRenderer.strategy, named: "\(theme.name)-\(name)")
            }
        }
    }

    /// The draft after Return (spec 4.3): at work, failed, and showing the result.
    func testDraftPhases() {
        for theme in Self.themes {
            for phase in ["writing", "structuring", "failed", "result"] {
                let draft = DraftView(frame: NSRect(x: 0, y: 0, width: 232, height: 160))
                draft.appearance = NSAppearance(named: theme.appearance)
                draft.paper = .default
                draft.textView.string = "Сначала забрать посылку, потом оплатить интернет"
                switch phase {
                case "writing": draft.refresh()
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

    /// The line about headings, points and tasks on a Russian layout (spec 18.5).
    func testDraftHintOnARussianLayout() {
        MarkupHint.forcedRussianLayout = true
        defer { MarkupHint.forcedRussianLayout = false }
        let draft = DraftView(frame: NSRect(x: 0, y: 0, width: 232, height: 160))
        draft.appearance = NSAppearance(named: .aqua)
        draft.paper = .default
        draft.refresh()
        draft.frame = NSRect(x: 0, y: 0, width: 232, height: max(draft.height(fittingWidth: 232), 160))
        assertSnapshot(of: SnapshotRenderer.image(of: draft), as: SnapshotRenderer.strategy)
    }

    func testDraft() {
        MarkupHint.forcedRussianLayout = false
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
