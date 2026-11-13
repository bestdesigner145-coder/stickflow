// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

#if DEBUG
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
            environment.preferences.hideFromScreenSharing = false
            stickers.applyPreferences()

            if let screen = environment.displays.menuBarScreen {
                note("screen frame \(screen.frame), visible \(screen.visibleFrame), scale \(screen.backingScaleFactor)")
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
                if case .checkbox(let line) = controller.rootView.zone(at: NSPoint(x: paperRect.minX + 18, y: y)) {
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
            check(controller.mode == .rest, "no fade before the delay")
            controller.pointerDidUpdate(sample(inside, at: tuning.fadeDelay + 0.01))
            check(controller.mode == .faded, "the sticker fades under the cursor after the delay")
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
            } else {
                check(false, "a second sticker is created")
            }

            // 9. What is really on screen, blur included. Needs screen-recording permission; optional.
            if let screen = environment.displays.menuBarScreen {
                let area = controller.panel.frame.union(stickers.controllers.last?.panel.frame ?? controller.panel.frame)
                let captured = captureScreen(area, on: screen, name: "7-screen")
                note("screen capture written: \(captured)")

                // The same area with "hide from screen sharing" on, to see what this macOS does with it.
                environment.preferences.hideFromScreenSharing = true
                stickers.applyPreferences()
                await pause(0.4)
                _ = captureScreen(area, on: screen, name: "8-screen-hidden")
                environment.preferences.hideFromScreenSharing = false
                stickers.applyPreferences()
            }

            // 10. Persistence and peeling.
            do {
                check(try environment.repository.stickers(status: .active).count == 2, "two active stickers are stored")
                stickers.peel(controller)
                check(try environment.repository.stickers(status: .active).count == 1, "peeling removes the sticker from the active list")
                check(try environment.repository.stickers(status: .draft).count == 1, "a peeled sticker with open tasks becomes a draft")
                check(stickers.controllers.count == 1, "the peeled sticker leaves the screen")
            } catch {
                check(false, "the repository can be queried (\(error))")
            }
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

        private func write(_ rep: NSBitmapImageRep, name: String) {
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: output.appendingPathComponent("\(name).png"))
        }

        /// Uses the system `screencapture` tool. Returns false when it is not allowed to run.
        func captureScreen(_ rect: CGRect, on screen: NSScreen, name: String) -> Bool {
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
#endif
