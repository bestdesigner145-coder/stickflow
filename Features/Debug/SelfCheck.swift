// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

#if DEBUG
// The self-check is one long scripted scenario with wordy check labels;
// the size and length limits are for product code.
// swiftlint:disable function_body_length cyclomatic_complexity large_tuple line_length type_body_length
import AppKit
import StickflowCore

/// Scripted run for CI: `Stickflow --self-check <output directory>`.
///
/// Nobody can click through the app on a build machine. This mode drives the
/// real editing path (the same calls the keyboard makes), checks what ends up
/// in the model and in the database, and writes PNG snapshots of the stickers
/// for a human to look at. It uses its own database inside the output directory
/// and never touches the user's stickers.
@MainActor
enum SelfCheck {
    /// Directory passed after `--self-check`, or `nil` in a normal launch.
    static var outputDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--self-check"), index + 1 < arguments.count else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static var isActive: Bool { outputDirectory != nil }

    /// A fresh database for this run, or `nil` in a normal launch.
    static func prepareDatabaseURL() -> URL? {
        guard let output = outputDirectory else { return nil }
        let data = output.appendingPathComponent("data", isDirectory: true)
        try? FileManager.default.removeItem(at: data)
        return data.appendingPathComponent("db.sqlite", isDirectory: false)
    }

    static func run(in environment: AppEnvironment, output: URL) {
        Task { @MainActor in
            var session = Session(environment: environment, output: output)
            await session.perform()
            session.finish()
        }
    }

    // MARK: - Session

    @MainActor
    private struct Session {
        let environment: AppEnvironment
        let output: URL
        var lines: [String] = []
        var failures = 0

        init(environment: AppEnvironment, output: URL) {
            self.environment = environment
            self.output = output
        }

        mutating func check(_ condition: Bool, _ label: String) {
            lines.append("\(condition ? "PASS" : "FAIL")  \(label)")
            if !condition { failures += 1 }
        }

        mutating func note(_ text: String) {
            lines.append("INFO  \(text)")
        }

        func pause(_ seconds: Double) async {
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        }

        func finish() -> Never {
            let summary = failures == 0 ? "SELF-CHECK OK" : "SELF-CHECK FAILED: \(failures)"
            let text = (lines + [summary]).joined(separator: "\n") + "\n"
            print(text)
            try? text.write(to: output.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            exit(failures == 0 ? 0 : 1)
        }

        // MARK: Script

        mutating func perform() async {
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let stickers = environment.stickers
            let tuning = environment.tuning
            let editKey = environment.preferences.editKey.flag

            // Snapshots must show the sticker; do not persist this change.
            environment.preferences.hideFromScreenCapture = false
            environment.preferences.hideDuringScreenSharing = false
            stickers.applyPreferences()
            note("system Reduce Motion: \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)")
            // The scenario checks the animated paths whatever the runner's settings are.
            tuning.forcedReduceMotion = false
            let watcher = stickers.captureWatcher
            note("screen-capture probe: available \(watcher.isAvailable), captured now \(String(describing: watcher.readNow()))")

            if let screen = environment.displays.menuBarScreen {
                note("screen frame \(screen.frame), visible \(screen.visibleFrame), scale \(NSScreen.screens.first?.backingScaleFactor ?? 0)")
            } else {
                check(false, "a screen is available")
                return
            }

            // 1. Quick input creates a sticker and starts editing it.
            let ownBundleID = Bundle.main.bundleIdentifier
            let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            note("frontmost app before: \(frontBefore ?? "none"), Stickflow active: \(NSApp.isActive)")
            stickers.createSticker()
            await pause(0.4)
            guard let controller = stickers.controllers.last else {
                check(false, "quick input creates a sticker")
                return
            }
            let textView = controller.rootView.textView
            check(controller.mode == .editing, "a new sticker starts in editing")
            check(controller.panel.isKeyWindow, "the panel has keyboard focus while editing")
            // A busy runner may start the first animation late: give it time before judging.
            for _ in 0..<20 where controller.panel.alphaValue < 0.98 {
                await pause(0.1)
            }
            check(abs(Double(controller.panel.alphaValue) - 1) < 0.02, "the new sticker has finished appearing (alpha \(controller.panel.alphaValue))")
            let frontWhileEditing = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            note("frontmost app while editing: \(frontWhileEditing ?? "none"), Stickflow active: \(NSApp.isActive)")
            if let frontBefore, frontBefore != ownBundleID {
                check(frontWhileEditing == frontBefore, "editing does not take the other app out of the foreground")
            }

            if let screen = environment.displays.menuBarScreen {
                let visible = screen.visibleFrame
                let paper = controller.paperFrame
                let expectedRight = visible.maxX - CGFloat(tuning.anchorInsetRight)
                let expectedTop = visible.maxY - CGFloat(tuning.anchorInsetTop)
                check(
                    abs(paper.maxX - expectedRight) <= 1 && abs(paper.maxY - expectedTop) <= 1,
                    "the sticker sits at the default anchor (paper \(paper), expected top-right \(expectedRight), \(expectedTop))"
                )
            }

            // 2. Type through the same entry points the keyboard uses.
            func typeText(_ text: String) {
                textView.insertText(text, replacementRange: textView.selectedRange())
            }
            typeText("План на день")
            textView.insertNewline(nil)
            typeText("## ")
            typeText("Кошелёк")
            textView.insertNewline(nil)
            typeText("Доделать экран")
            textView.insertNewline(nil)
            textView.insertTab(nil)
            typeText("- ")
            typeText("пустые состояния")
            textView.insertNewline(nil)
            textView.insertBacktab(nil)
            typeText("[x] ")
            typeText("Созвон с разработкой 15:00")
            textView.insertNewline(nil)
            typeText("Написать пост")
            await pause(0.4)

            note("editor text: \(textView.string.replacingOccurrences(of: "\n", with: " ⏎ "))")
            note("editor kinds: \(textView.metas.map { "\($0.kind.rawValue)/\($0.indent)\($0.done ? "/done" : "")" }.joined(separator: ", "))")
            snapshot(controller, name: "1-editing")

            // 3. Leaving editing commits the text and returns to the click-through state.
            controller.endEditing()
            await pause(0.6)
            check(controller.mode == .rest, "ending editing returns to rest")
            check(!controller.panel.isKeyWindow, "the panel gives keyboard focus back")
            check(controller.panel.ignoresMouseEvents, "at rest the panel ignores the mouse")
            check(controller.panel.isVisible, "the sticker stays on screen after editing")
            check(NSApp.keyWindow == nil, "no Stickflow window keeps the keyboard after editing (key window: \(String(describing: NSApp.keyWindow)))")
            check(stickers.focusReturnFallbacks == 0, "the keyboard went back without hiding the sticker (fallbacks: \(stickers.focusReturnFallbacks))")
            let frontAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            note("frontmost app after editing: \(frontAfter ?? "none"), Stickflow active: \(NSApp.isActive)")
            if let frontBefore, frontBefore != ownBundleID {
                check(frontAfter == frontBefore, "after editing the other app is still in the foreground")
            }

            let expected: [(kind: Block.Kind, text: String, indent: Int, done: Bool)] = [
                (.heading2, "Кошелёк", 0, false),
                (.todo, "Доделать экран", 0, false),
                (.bullet, "пустые состояния", 1, false),
                (.todo, "Созвон с разработкой 15:00", 0, true),
                (.todo, "Написать пост", 0, false),
            ]
            let actual = controller.sticker.blocks
            let matches = actual.count == expected.count && zip(actual, expected).allSatisfy { block, want in
                block.kind == want.kind && block.text == want.text && block.indent == want.indent && block.done == want.done
            }
            check(controller.sticker.title == "План на день", "title is saved (\(controller.sticker.title))")
            check(matches, "blocks are saved as typed: \(actual.map { "\($0.kind.rawValue)/\($0.indent)\($0.done ? "/done" : ""):\($0.text)" })")
            check(controller.sticker.taskCount == TaskCount(done: 1, total: 3), "counter is 1/3 (\(controller.sticker.taskCount.label))")
            note("paper frame at rest \(controller.paperFrame)")
            snapshot(controller, name: "2-rest")

            // 4. Checkbox hit-testing: scan a vertical line through the checkbox column.
            let paperRect = controller.rootView.paperRect
            var hitLines = Set<Int>()
            var y = paperRect.minY
            while y < paperRect.maxY {
                if case let .checkbox(line) = controller.rootView.zone(at: NSPoint(x: paperRect.minX + 18, y: y)) {
                    hitLines.insert(line)
                }
                y += 2
            }
            // Editor lines: 0 title, 1 heading, 2 task, 3 nested bullet, 4 task, 5 task.
            check(hitLines == [2, 4, 5], "checkbox hit-testing finds the three tasks (found \(hitLines.sorted()))")
            if case .glueStrip = controller.rootView.zone(at: NSPoint(x: paperRect.midX, y: paperRect.minY + 4)) {
                check(true, "the top strip is the drag zone")
            } else {
                check(false, "the top strip is the drag zone")
            }

            // 5. Pointer state machine, fed with synthetic samples.
            let inside = CGPoint(x: controller.paperFrame.midX, y: controller.paperFrame.midY)
            let outside = CGPoint(x: controller.paperFrame.minX - 300, y: controller.paperFrame.minY - 300)
            let start = ProcessInfo.processInfo.systemUptime
            func sample(_ location: CGPoint, key: Bool = false, mouse: Bool = false, at offset: Double) -> PointerSample {
                PointerSample(location: location, modifiers: key ? editKey : [], isMouseDown: mouse, time: start + offset)
            }

            controller.pointerDidUpdate(sample(inside, at: 0))
            check(controller.mode == .faded, "the sticker starts to fade the moment the cursor is over it, with no pause")
            await pause(0.35)
            check(abs(Double(controller.panel.alphaValue) - tuning.fadedOpacity) < 0.02, "faded window alpha is \(tuning.fadedOpacity) (is \(controller.panel.alphaValue))")
            check(controller.panel.ignoresMouseEvents, "a faded sticker still ignores the mouse")

            controller.pointerDidUpdate(sample(inside, key: true, mouse: true, at: 1.0))
            check(controller.mode == .faded, "the edit key does nothing while a mouse button is down")
            controller.pointerDidUpdate(sample(inside, key: true, at: 1.1))
            check(controller.mode == .editMode, "the edit key over the sticker enters edit mode")
            check(!controller.panel.ignoresMouseEvents, "in edit mode the panel accepts clicks")
            await pause(0.35)
            check(abs(Double(controller.panel.alphaValue) - 1) < 0.02, "edit mode is fully opaque (alpha \(controller.panel.alphaValue))")
            snapshot(controller, name: "3-edit-mode")

            controller.pointerDidUpdate(sample(inside, at: 2.0))
            check(controller.mode == .editMode, "edit mode survives the release grace period")
            controller.pointerDidUpdate(sample(inside, at: 2.0 + tuning.editKeyReleaseGrace + 0.01))
            check(controller.mode == .rest, "releasing the edit key returns to click-through")
            check(controller.panel.ignoresMouseEvents, "after edit mode the panel ignores the mouse again")
            controller.pointerDidUpdate(sample(outside, at: 3.0))
            await pause(0.3)

            // 5a. The cursor's halo (spec 4.7): a sticker near the cursor fades too, less with distance.
            let paper = controller.paperFrame
            let middle = (tuning.haloCore + tuning.haloRadius) / 2
            controller.pointerDidUpdate(sample(CGPoint(x: paper.minX - middle, y: paper.midY), at: 3.5))
            check(controller.mode == .faded, "a sticker inside the cursor's halo fades without the cursor on it")
            check(controller.panel.ignoresMouseEvents, "a sticker faded by the halo still ignores the mouse")
            await pause(0.35)
            let halfFaded = (1 + tuning.fadedOpacity) / 2
            check(abs(Double(controller.panel.alphaValue) - halfFaded) < 0.03, "half way into the halo it is half faded (alpha \(controller.panel.alphaValue), expected \(halfFaded))")
            controller.pointerDidUpdate(sample(CGPoint(x: paper.minX - tuning.haloCore + 4, y: paper.midY), at: 3.6))
            await pause(0.35)
            check(abs(Double(controller.panel.alphaValue) - tuning.fadedOpacity) < 0.02, "close by, the opacity follows the cursor down to \(tuning.fadedOpacity) (is \(controller.panel.alphaValue))")
            controller.pointerDidUpdate(sample(CGPoint(x: paper.minX - middle, y: paper.midY), key: true, at: 3.7))
            check(controller.mode == .rest, "the edit key switches the halo off")
            controller.pointerDidUpdate(sample(CGPoint(x: paper.minX - tuning.haloRadius - 2, y: paper.midY), at: 3.8))
            check(controller.mode == .rest, "beyond the halo the sticker is at rest")
            controller.pointerDidUpdate(sample(outside, at: 3.9))
            await pause(0.3)
            check(abs(Double(controller.panel.alphaValue) - 1) < 0.02, "away from the cursor the sticker is opaque again (alpha \(controller.panel.alphaValue))")

            // 6. Ticking a task outside editing is saved.
            textView.toggleDone(line: 5)
            await pause(0.7) // debounced save
            check(controller.sticker.taskCount == TaskCount(done: 2, total: 3), "ticking a task updates the counter (\(controller.sticker.taskCount.label))")
            do {
                let live = controller.sticker
                if let saved = try environment.repository.sticker(id: live.id) {
                    check(saved.title == live.title, "stored title matches")
                    check(saved.blocks == live.blocks, "stored blocks match, completion dates included")
                    check(saved.status == live.status && saved.color == live.color && saved.source == live.source, "stored status, colour and source match")
                    check(saved.placement == live.placement, "stored placement matches (\(String(describing: saved.placement)) vs \(String(describing: live.placement)))")
                    // The database keeps dates with millisecond precision.
                    let drift = abs(saved.updatedAt.timeIntervalSince(live.updatedAt))
                    check(drift < 0.002, "stored modification date matches within 2 ms (drift \(drift))")
                } else {
                    check(false, "the sticker is in the database")
                }
            } catch {
                check(false, "the sticker can be read back (\(error))")
            }

            // 7. Dark appearance.
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await pause(0.4)
            check(controller.panel.isVisible && abs(Double(controller.panel.alphaValue) - 1) < 0.02, "the sticker stays on screen through a theme change")
            snapshot(controller, name: "4-rest-dark")
            NSApp.appearance = nil
            await pause(0.3)

            // 8. A long sticker is capped in height; a second sticker is cascaded.
            stickers.createSticker()
            await pause(0.4)
            if let long = stickers.controllers.last, long !== controller {
                let longText = long.rootView.textView
                longText.insertText("Длинный список", replacementRange: longText.selectedRange())
                for index in 1...16 {
                    longText.insertNewline(nil)
                    longText.insertText("Задача номер \(index)", replacementRange: longText.selectedRange())
                }
                await pause(0.3)
                snapshot(long, name: "5-long-editing")
                long.endEditing()
                await pause(0.5)
                check(long.paperFrame.height <= CGFloat(tuning.maxPaperHeight) + 1, "a long sticker is capped at \(tuning.maxPaperHeight) pt (is \(long.paperFrame.height))")
                check(long.sticker.blocks.count == 16, "the long sticker keeps all 16 tasks (\(long.sticker.blocks.count))")
                let offset = CGFloat(tuning.cascadeOffset)
                check(
                    abs(long.paperFrame.maxX - (controller.paperFrame.maxX - offset)) <= 1
                        && abs(long.paperFrame.maxY - (controller.paperFrame.maxY - offset)) <= 1,
                    "the second sticker is cascaded by \(offset) pt (first \(controller.paperFrame), second \(long.paperFrame))"
                )
                snapshot(long, name: "6-long-rest")

                // With the edit key held a long sticker scrolls right away, no click (fix F1).
                let longInside = CGPoint(x: long.paperFrame.midX, y: long.paperFrame.midY)
                long.pointerDidUpdate(sample(longInside, key: true, at: 10.0))
                check(long.mode == .editMode, "the long sticker enters edit mode")
                let scrolled = long.rootView.scrollText(by: 60)
                check(scrolled && long.rootView.scrollOffset > 40, "with the edit key a long sticker scrolls without a click (offset \(long.rootView.scrollOffset))")
                await pause(0.2)
                snapshot(long, name: "6b-long-scrolled")
                long.rootView.scrollText(by: 10000)
                note("long sticker scrolled to the end: offset \(long.rootView.scrollOffset)")
                await pause(0.2)
                snapshot(long, name: "6c-long-scrolled-end")
                // Well beyond the cursor's halo of this sticker.
                let clear = CGPoint(x: long.paperFrame.minX - 400, y: long.paperFrame.minY - 400)
                long.pointerDidUpdate(sample(clear, at: 11.0))
                long.pointerDidUpdate(sample(clear, at: 11.0 + tuning.editKeyReleaseGrace + 0.01))
                check(long.mode == .rest, "the long sticker returns to rest")
                await pause(0.5)
                check(long.rootView.scrollOffset < 0.5, "at rest the long sticker shows its beginning again (offset \(long.rootView.scrollOffset))")
            } else {
                check(false, "a second sticker is created")
            }

            // 9. What is really on screen, blur included. Needs screen-recording permission; optional.
            if let screen = environment.displays.menuBarScreen {
                let area = controller.panel.frame.union(stickers.controllers.last?.panel.frame ?? controller.panel.frame)
                let captured = captureScreen(area, on: screen, name: "7-screen")
                note("screen capture written: \(captured)")

                // The same area with "keep out of screenshots" on, to see what this macOS does with it.
                environment.preferences.hideFromScreenCapture = true
                stickers.applyPreferences()
                await pause(0.4)
                _ = captureScreen(area, on: screen, name: "8-screen-hidden")
                environment.preferences.hideFromScreenCapture = false
                stickers.applyPreferences()
            }

            // 10. Peeling, the toast and the ways back (spec 4.10; fixes F6–F9).
            let firstID = controller.sticker.id
            let firstFrame = controller.paperFrame
            do {
                try check(environment.repository.stickers(status: .active).count == 2, "two active stickers are stored")
                check(!stickers.canRestoreLastPeeled, "nothing to restore before the first peel")
                stickers.peel(controller)
                try check(environment.repository.stickers(status: .active).count == 1, "peeling removes the sticker from the active list")
                try check(environment.repository.stickers(status: .draft).count == 1, "a peeled sticker with open tasks becomes a draft")
                try check(environment.repository.lastPeeled()?.id == firstID, "the peeled sticker is stored with the time it was peeled")
                check(stickers.controllers.count == 1, "the peeled sticker is off the list at once")
                check(stickers.isUndoToastVisible, "peeling shows the toast")
                check(stickers.canRestoreLastPeeled, "the menu bar can restore the last peeled sticker")
                await pause(0.35)
                snapshotToast(name: "9-toast")
                if let screen = environment.displays.menuBarScreen, let frame = stickers.toastSnapshotView?.window?.frame {
                    _ = captureScreen(frame.insetBy(dx: -24, dy: -24), on: screen, name: "9b-screen-toast")
                }
                await pause(0.3)
                check(controller.isClosed, "the peeled sticker's window closes when its animation ends")

                stickers.undoLastPeel()
                await pause(0.6)
                if let restored = stickers.controllers.first(where: { $0.sticker.id == firstID }) {
                    check(restored.sticker.status == .active && restored.sticker.peeledAt == nil, "Restore in the toast makes the sticker active again")
                    check(
                        abs(restored.paperFrame.minX - firstFrame.minX) <= 1 && abs(restored.paperFrame.maxY - firstFrame.maxY) <= 1,
                        "it comes back to the same place (was \(firstFrame), is \(restored.paperFrame))"
                    )
                    check(restored.panel.isVisible && abs(Double(restored.panel.alphaValue) - 1) < 0.02, "the restored sticker has finished appearing (alpha \(restored.panel.alphaValue))")
                    check(restored.sticker.blocks.count == 5, "the restored sticker keeps its blocks (\(restored.sticker.blocks.count))")
                } else {
                    check(false, "Restore in the toast brings the sticker back")
                }
                check(!stickers.isUndoToastVisible, "the toast goes away after Restore")
                try check(environment.repository.stickers(status: .active).count == 2, "both stickers are active again")
                check(!stickers.canRestoreLastPeeled, "nothing is left to restore")

                // One action takes everything off, one toast brings everything back.
                stickers.peelAll()
                check(stickers.controllers.isEmpty, "“Peel off all” takes every sticker off")
                try check(environment.repository.stickers(status: .active).isEmpty, "no sticker stays active after “Peel off all”")
                await pause(0.4)
                snapshotToast(name: "10-toast-all")
                stickers.undoLastPeel()
                await pause(0.6)
                check(stickers.controllers.count == 2, "one Restore brings all of them back (\(stickers.controllers.count))")

                // The menu-bar way back, without the toast.
                if let again = stickers.controllers.first(where: { $0.sticker.id == firstID }) {
                    stickers.peel(again)
                    await pause(0.4)
                    stickers.restoreLastPeeled()
                    await pause(0.5)
                    check(stickers.controllers.contains { $0.sticker.id == firstID }, "“Restore last peeled” brings the sticker back")
                    check(!stickers.isUndoToastVisible, "restoring from the menu bar dismisses the toast")
                }

                // Hide all and show all (the quick way out before sharing the screen).
                stickers.toggleStickersHidden()
                check(stickers.controllers.allSatisfy { !$0.panel.isVisible }, "“hide all” takes every sticker off the screen at once")
                stickers.toggleStickersHidden()
                await pause(0.5)
                check(stickers.controllers.allSatisfy { $0.panel.isVisible && abs(Double($0.panel.alphaValue) - 1) < 0.02 }, "“show all” brings them back")

                // Screen sharing (spec 5.2): stickers go at once and come back a moment after it ends.
                stickers.screenCaptureDidChange(true)
                check(stickers.controllers.allSatisfy { !$0.panel.isVisible }, "a screen capture hides every sticker at once")
                stickers.screenCaptureDidChange(false)
                await pause(0.4)
                check(stickers.controllers.allSatisfy { !$0.panel.isVisible }, "stickers stay hidden for a moment after the capture ends")
                await pause(1.2)
                check(stickers.controllers.allSatisfy { $0.panel.isVisible && abs(Double($0.panel.alphaValue) - 1) < 0.02 }, "then they come back")
            } catch {
                check(false, "the repository can be queried (\(error))")
            }

            // 11. "[] " typed where those keys give letters (fix F12). On a Russian
            // layout "[", "]" and space type "х", "ъ" and a space.
            stickers.createSticker()
            await pause(0.4)
            if let probe = stickers.controllers.last, probe.mode == .editing {
                let probeText = probe.rootView.textView
                probeText.insertText("Проба клавиш", replacementRange: probeText.selectedRange())
                probeText.insertNewline(nil)
                probeText.deleteBackward(nil) // the new line starts as a task; make it plain text
                check(probeText.metas.last?.kind == .text, "the probe line starts as plain text")

                let keys: [(code: UInt16, characters: String)] = [(33, "х"), (30, "ъ"), (49, " ")]
                var textAfterTwoKeys = ""
                for (index, key) in keys.enumerated() {
                    if let event = NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: probe.panel.windowNumber,
                        context: nil,
                        characters: key.characters,
                        charactersIgnoringModifiers: key.characters,
                        isARepeat: false,
                        keyCode: key.code
                    ) {
                        probeText.keyDown(with: event)
                    }
                    if index == 1 { textAfterTwoKeys = probeText.string }
                }
                await pause(0.2)
                note("probe after two keys: «\(textAfterTwoKeys.replacingOccurrences(of: "\n", with: " ⏎ "))»; after three: «\(probeText.string.replacingOccurrences(of: "\n", with: " ⏎ "))», kinds \(probeText.metas.map { $0.kind.rawValue })")
                check(textAfterTwoKeys.hasSuffix("хъ"), "the synthetic keys typed Russian letters, so the test exercises key positions")
                check(
                    probeText.metas.last?.kind == .todo && probeText.string == "Проба клавиш\n",
                    "“[] ” on a Russian layout turns the line into a task"
                )

                // Empty the probe: a sticker without text is discarded when editing ends.
                probeText.selectAll(nil)
                probeText.deleteBackward(nil)
                probe.endEditing()
                await pause(0.3)
                check(!stickers.controllers.contains { $0 === probe }, "the emptied probe sticker is discarded")
            } else {
                check(false, "a probe sticker is created for the key test")
            }

            // 12. The way in (stage 2): call zone, pad and draft (spec 4.1–4.3).
            let entry = environment.entry
            entry.ignoresLivePointer = true
            if let zone = entry.zoneFrame {
                let spot = CGPoint(x: zone.midX, y: zone.midY)
                let far = CGPoint(x: zone.midX - 500, y: zone.midY)
                var clockTime = 1000.0
                func hold(_ location: CGPoint, for seconds: Double) {
                    let end = clockTime + seconds
                    while clockTime < end {
                        entry.pointerDidUpdate(
                            PointerSample(location: location, modifiers: [], isMouseDown: false, time: clockTime),
                            isScripted: true
                        )
                        clockTime += 1.0 / 60
                    }
                }
                note("call zone \(zone)")
                hold(spot, for: 0.2)
                check(entry.phase == .idle, "the pad stays hidden before the cursor has rested in the zone")
                hold(spot, for: 0.1)
                check(entry.phase == .peek, "a cursor resting in the zone makes the pad peek (\(entry.phase))")
                check(abs((entry.visiblePadFrame?.width ?? 0) - CGFloat(tuning.padPeekReach)) < 1, "the pad peeks out by 28 pt (\(String(describing: entry.visiblePadFrame)))")
                hold(spot, for: 0.3)
                check(entry.phase == .open, "staying a little longer brings the pad out (\(entry.phase))")
                check(abs((entry.visiblePadFrame?.width ?? 0) - CGFloat(tuning.padOpenReach)) < 1, "the pad comes out by 96 pt")
                await pause(0.5)
                snapshotView(entry.padSnapshotView, name: "12-pad")
                if let screen = environment.displays.menuBarScreen {
                    _ = captureScreen(entry.padWindowFrameForSnapshot.insetBy(dx: -20, dy: -20), on: screen, name: "12b-screen-pad")
                }

                let stickersBefore = stickers.controllers.count
                entry.openDraft(from: .pad)
                await pause(0.5)
                let draft = entry.draft
                check(draft.isOpen, "a click on the pad opens the draft")
                check(draft.rootView.window?.isKeyWindow == true, "the draft has the keyboard")
                note("frontmost app with the draft open: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
                if let padFrame = entry.visiblePadFrame, let draftFrame = draft.rootView.window?.frame {
                    check(abs(padFrame.minX - draftFrame.maxX - CGFloat(tuning.draftGap)) < 1, "the draft stands next to the pad, not in the middle of the screen (\(draftFrame))")
                    check(abs(draftFrame.midY - zone.midY) < 1, "the draft is centred on the pad")
                }
                check(!draft.rootView.stickButton.isEnabled, "the tick is off while the draft is empty")
                snapshotView(draft.rootView, name: "13-draft-empty")
                draft.rootView.textView.insertText("План\nКупить молоко\n- заметка", replacementRange: draft.rootView.textView.selectedRange())
                await pause(0.2)
                check(draft.rootView.stickButton.isEnabled, "the tick is on once there is text")
                snapshotView(draft.rootView, name: "13b-draft-text")
                if let screen = environment.displays.menuBarScreen, let draftFrame = draft.rootView.window?.frame {
                    let area = draftFrame.union(entry.padWindowFrameForSnapshot).insetBy(dx: -20, dy: -20)
                    _ = captureScreen(area, on: screen, name: "13c-screen-draft")
                }
                hold(far, for: 1.0)
                check(entry.phase == .open, "the pad stays out while the draft is open")

                draft.submit()
                await pause(0.12)
                check(stickers.controllers.last?.isAirborne == true, "the new sticker flies from the draft to its place")
                // The flight is a picture in the overlay; the window itself does not move (fix G5).
                check(stickers.controllers.last?.isDrawnInOverlay == true && stickers.effectsOverlay.isVisible, "it flies as a picture in the effects overlay")
                check(stickers.controllers.last?.panel.isVisible == false, "its own window waits for the landing")
                await pause(1.0)
                check(stickers.controllers.last?.isAirborne == false, "the flight ends")
                check(stickers.controllers.last?.panel.isVisible == true, "the window appears where the picture landed")
                check(stickers.effectsOverlay.spriteCount == 0 && !stickers.effectsOverlay.isVisible, "and the overlay is gone (\(stickers.effectsOverlay.spriteCount) left)")
                check(!draft.isOpen, "sticking closes the draft")
                check(NSApp.keyWindow == nil, "the keyboard goes back after the draft closes")
                check(stickers.controllers.count == stickersBefore + 1, "the draft becomes a sticker")
                if let stuck = stickers.controllers.last {
                    let got = stuck.sticker.blocks.map { "\($0.kind.rawValue):\($0.text)" }
                    check(stuck.sticker.title == "План" && got == ["todo:Купить молоко", "bullet:заметка"], "its lines become the title and the blocks (\(stuck.sticker.title), \(got))")
                    check(stuck.sticker.rawInput == "План\nКупить молоко\n- заметка", "the text as typed is kept with the sticker")
                    check(stuck.mode == .rest && abs(Double(stuck.panel.alphaValue) - 1) < 0.02, "after landing the sticker is at rest")
                    let landed = stuck.paperFrame
                    await pause(0.3)
                    check(stuck.paperFrame == landed, "and it stays where it landed (\(landed))")
                }
                hold(far, for: 0.5)
                check(entry.phase == .idle, "with the draft gone and the cursor away the pad hides")

                // The hotkey path, and Esc: the text is kept as a draft.
                entry.toggleDraft()
                await pause(0.4)
                check(draft.isOpen && entry.phase == .open, "the quick-input hotkey opens the draft and brings the pad out")
                draft.rootView.textView.insertText("Отложенное", replacementRange: draft.rootView.textView.selectedRange())
                entry.toggleDraft()
                await pause(0.4)
                check(!draft.isOpen, "the hotkey pressed again closes the draft")
                do {
                    let drafts = try environment.repository.stickers(status: .draft)
                    check(drafts.contains { $0.title == "Отложенное" }, "a closed draft is kept (\(drafts.map(\.title)))")
                } catch {
                    check(false, "drafts can be read (\(error))")
                }

                // An empty draft closes itself when the user turns away (fix G3).
                do {
                    let draftsBefore = try environment.repository.stickers(status: .draft).count
                    entry.toggleDraft()
                    await pause(0.4)
                    check(draft.isOpen, "the hotkey opens an empty draft")
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
                    await pause(0.4)
                    check(!draft.isOpen, "an empty draft closes when the desktop changes")
                    entry.toggleDraft()
                    await pause(0.4)
                    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: draft.rootView.window)
                    await pause(0.4)
                    check(!draft.isOpen, "an empty draft closes when the keyboard goes elsewhere")
                    try check(environment.repository.stickers(status: .draft).count == draftsBefore, "an empty draft leaves nothing behind")

                    entry.toggleDraft()
                    await pause(0.4)
                    draft.rootView.textView.insertText("Недописанное", replacementRange: draft.rootView.textView.selectedRange())
                    draft.attentionDidLeave()
                    await pause(0.4)
                    check(draft.isOpen && draft.text == "Недописанное", "a draft with text stays when focus is lost")
                    tuning.draftWithTextClosesOnFocusLoss = true
                    draft.attentionDidLeave()
                    await pause(0.4)
                    tuning.draftWithTextClosesOnFocusLoss = false
                    check(!draft.isOpen, "with the Tuning switch a draft with text closes when focus is lost")
                    let kept = try environment.repository.stickers(status: .draft)
                    check(kept.contains { $0.title == "Недописанное" }, "and is kept as a draft (\(kept.map(\.title)))")
                } catch {
                    check(false, "drafts can be read (\(error))")
                }

                // Screen sharing hides the way in together with the stickers (spec 5.2).
                stickers.screenCaptureDidChange(true)
                entry.toggleDraft()
                check(!draft.isOpen, "no draft while the screen is captured")
                stickers.screenCaptureDidChange(false)
                await pause(1.3)
            } else {
                check(false, "there is a call zone on the sticker screen")
            }
            entry.ignoresLivePointer = false

            // 13. Peeling by the corner (spec 4.10).
            if let target = stickers.controllers.last {
                let countBefore = stickers.controllers.count
                let corner = CGPoint(x: target.paperFrame.maxX - 6, y: target.paperFrame.minY + 6)
                var moment = ProcessInfo.processInfo.systemUptime
                func pull(by step: CGFloat, steps: Int, every interval: Double) -> CGPoint {
                    var location = corner
                    for index in 1...steps {
                        moment += interval
                        location = CGPoint(x: corner.x - step * CGFloat(index), y: corner.y + step * CGFloat(index))
                        target.updatePeel(to: location, time: moment)
                    }
                    return location
                }

                // A short, slow pull: the corner follows, then springs back.
                target.beginPeel(at: corner, time: moment)
                var released = pull(by: 3, steps: 10, every: 0.05)
                check(target.isPeeling, "the corner can be pulled")
                await pause(0.3)
                // The pulled sticker is a picture in the overlay; its window is hidden,
                // so nothing of it is left where the paper has gone (fixes G1, G2).
                check(target.isDrawnInOverlay && stickers.effectsOverlay.isVisible, "the pulled sticker is drawn in the effects overlay")
                check(Double(target.panel.alphaValue) < 0.01, "its own window is invisible meanwhile (alpha \(target.panel.alphaValue))")
                check(target.visibleFold != nil, "the corner is folded over")
                if let screen = environment.displays.menuBarScreen {
                    _ = captureScreen(target.panel.frame, on: screen, name: "14-screen-fold")
                }
                target.endPeel(at: released, time: moment + 0.3)
                await pause(1.0)
                check(!target.isPeeling && !target.isClosed, "pulled 42 pt and let go slowly, the corner springs back")
                check(stickers.controllers.count == countBefore, "and the sticker stays")
                check(!target.isDrawnInOverlay && abs(Double(target.panel.alphaValue) - 1) < 0.02, "the window is back in place of the picture (alpha \(target.panel.alphaValue))")
                check(!stickers.effectsOverlay.isVisible, "and the overlay is gone")

                // A long pull, past the top of the sheet: the folded paper leaves the
                // sticker's own rectangle and is not cut off; past 70 pt the sticker comes off.
                moment = ProcessInfo.processInfo.systemUptime
                target.beginPeel(at: corner, time: moment)
                let reach = target.paperFrame.height + 60
                released = pull(by: reach / 10, steps: 10, every: 0.03)
                await pause(0.2)
                if let fold = target.visibleFold {
                    let top = fold.flap.map(\.y).min() ?? 0
                    check(top < -40, "the folded paper reaches \(Int(-top)) pt beyond the sheet, farther than the old window margin")
                } else {
                    check(false, "a long pull folds the sheet")
                }
                if let screen = environment.displays.menuBarScreen {
                    _ = captureScreen(target.panel.frame.insetBy(dx: -60, dy: -60), on: screen, name: "14b-screen-fold-deep")
                }
                target.endPeel(at: released, time: moment + 0.2)
                check(stickers.controllers.count == countBefore - 1, "pulled \(Int(reach * 1.414)) pt, the sticker comes off")
                check(stickers.isUndoToastVisible, "and the toast offers to bring it back")
                await pause(0.7)
                check(target.isClosed, "the torn-off sticker flies away and its window closes")
                check(stickers.effectsOverlay.spriteCount == 0, "nothing is left in the overlay")

                // A short but quick jerk is enough too.
                if let quick = stickers.controllers.last {
                    let grip = CGPoint(x: quick.paperFrame.maxX - 6, y: quick.paperFrame.minY + 6)
                    let start = ProcessInfo.processInfo.systemUptime
                    quick.beginPeel(at: grip, time: start)
                    quick.updatePeel(to: CGPoint(x: grip.x - 10, y: grip.y + 10), time: start + 0.01)
                    quick.endPeel(at: CGPoint(x: grip.x - 24, y: grip.y + 24), time: start + 0.02)
                    check(stickers.controllers.count == countBefore - 2, "a quick jerk of 34 pt peels the sticker as well")
                    await pause(0.7)
                }
            } else {
                check(false, "there is a sticker to peel")
            }

            // 14. With "Reduce motion" a sticker appears in its place, without the flight.
            tuning.forcedReduceMotion = true
            entry.toggleDraft()
            await pause(0.3)
            entry.draft.rootView.textView.insertText("Без полёта", replacementRange: entry.draft.rootView.textView.selectedRange())
            entry.draft.submit(asIs: true)
            check(stickers.controllers.last?.isAirborne == false, "with Reduce Motion the sticker does not fly")
            await pause(0.5)
            check(stickers.controllers.last?.sticker.title == "Без полёта" && stickers.controllers.last?.panel.isVisible == true, "it appears in its place, stuck as it is")
            tuning.forcedReduceMotion = nil

            // 15. Return takes a dictated paragraph apart with the rules (spec 8).
            let countBeforePlan = stickers.controllers.count
            let dictated = "Короче, сначала надо доделать экран кошелька, там типа пустые состояния и ошибки, "
                + "потом созвон с разработкой в три, и если успею, условно, пост в телегу написать"
            entry.toggleDraft()
            await pause(0.3)
            entry.draft.rootView.textView.insertText(dictated, replacementRange: entry.draft.rootView.textView.selectedRange())
            entry.draft.submit()
            await pause(1.2)
            if stickers.controllers.count == countBeforePlan + 1, let planned = stickers.controllers.last {
                let lines = planned.sticker.blocks.map { "\($0.kind.rawValue):\($0.indent):\($0.text)" }
                let expected = [
                    "todo:0:Доделать экран кошелька", "bullet:1:пустые состояния", "bullet:1:ошибки",
                    "todo:0:Созвониться с разработкой в три", "heading2:0:Если успею", "todo:0:Написать пост в телегу",
                ]
                check(planned.sticker.title == "План на сегодня", "a dictated paragraph gets the default title (\(planned.sticker.title))")
                check(lines == expected, "the rules take it apart into tasks, details and an optional section (\(lines))")
                check(planned.sticker.rawInput == dictated, "what was said is kept with the sticker")
                check(!entry.draft.isOpen, "the draft closes once the plan is stuck")
                snapshot(planned, name: "16-structured")
            } else {
                check(false, "a dictated paragraph becomes a sticker (\(stickers.controllers.count - countBeforePlan) new)")
            }

            // 16. Dictation (spec 7): the microphone records, speech becomes text in the draft, Return makes a plan of it.
            let countBeforeVoice = stickers.controllers.count
            let voice = entry.draft.dictation
            entry.toggleDraft()
            await pause(0.3)
            voice.toggle()
            await pause(0.4)
            check(voice.state == .recording, "pressing the microphone starts a recording (\(voice.state))")
            check(entry.draft.rootView.dictation.state == .recording && voice.elapsed > 0, "the draft shows the recording and its timer runs (\(voice.elapsed))")
            snapshotView(entry.draft.rootView, name: "17-draft-recording")
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: entry.draft.rootView.window)
            await pause(0.2)
            check(entry.draft.isOpen, "an empty draft stays open while it listens")
            entry.draft.submit()
            check(entry.draft.isOpen, "Return does nothing while it listens")
            voice.toggle()
            await pause(0.5)
            check(voice.state == .idle, "pressing it again stops the recording (\(voice.state))")
            check(entry.draft.text == ScriptedSpeechEngine.sample, "what was said appears in the draft (\(entry.draft.text.prefix(40)))")
            entry.draft.submit()
            await pause(1.2)
            check(
                stickers.controllers.count == countBeforeVoice + 1 && stickers.controllers.last?.sticker.blocks.count == 6,
                "and Return makes a plan of it (\(stickers.controllers.last?.sticker.blocks.count ?? -1) lines)"
            )
            entry.toggleDraft()
            await pause(0.3)
            voice.toggle()
            await pause(0.3)
            entry.toggleDraft()
            await pause(0.3)
            check(voice.state == .idle && !entry.draft.isOpen, "closing the draft drops the recording (\(voice.state))")
        }

        // MARK: Snapshots

        /// Renders the sticker's view tree. The behind-window blur and the window
        /// alpha are not part of it; the screen capture at the end shows those.
        func snapshot(_ controller: StickerController, name: String) {
            let view = controller.rootView
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()

            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                write(rep, name: name)
            }
        }

        /// Renders any view the way it draws itself.
        func snapshotView(_ view: NSView, name: String) {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                write(rep, name: name)
            }
        }

        /// Renders the "Sticker peeled off · Restore" toast.
        func snapshotToast(name: String) {
            guard let view = environment.stickers.toastSnapshotView else { return }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                write(rep, name: name)
            }
        }

        private func write(_ rep: NSBitmapImageRep, name: String) {
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: output.appendingPathComponent("\(name).png"))
        }

        /// Uses the system `screencapture` tool. Returns false when it is not allowed to run.
        func captureScreen(_ rect: CGRect, on screen: ScreenInfo, name: String) -> Bool {
            let url = output.appendingPathComponent("\(name).png")
            // `screencapture -R` takes top-left based coordinates.
            let top = screen.frame.maxY - rect.maxY
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = [
                "-x",
                "-R", "\(Int(rect.minX)),\(Int(top)),\(Int(rect.width)),\(Int(rect.height))",
                url.path,
            ]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return false
            }
            return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
        }
    }
}
// swiftlint:enable function_body_length cyclomatic_complexity large_tuple line_length type_body_length
#endif
