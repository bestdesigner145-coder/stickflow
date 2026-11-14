// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import StickflowCore

@MainActor
protocol BlockTextViewDelegate: AnyObject {
    /// Text, a checkbox or the structure of a line changed.
    func blockTextViewDidChangeContent(_ textView: BlockTextView)
    /// The user pressed Esc.
    func blockTextViewDidRequestEndEditing(_ textView: BlockTextView)
    /// Any key press or click; restarts the idle timer.
    func blockTextViewDidInteract(_ textView: BlockTextView)
    /// ⌘+ / ⌘− pressed.
    func blockTextView(_ textView: BlockTextView, didRequestFontSizeChange delta: Int)
}

/// The block editor of a sticker (spec 4.8).
///
/// Every paragraph is one line: line 0 is the title, the rest are blocks. The
/// text view holds plain text, and `metas` describes each line (kind, nesting,
/// done). `LineSplicer` keeps the two in step when text changes.
///
/// Built on TextKit 1 on purpose: its layout is synchronous and predictable,
/// which the checkbox hit-testing and height measurement rely on.
final class BlockTextView: NSTextView {
    static let contentInset = NSSize(width: 12, height: 6)

    weak var blockDelegate: BlockTextViewDelegate?

    private(set) var metas: [LineMeta] = [LineMeta.title()]

    var style = BlockTextStyle() {
        didSet {
            if style != oldValue { restyle() }
        }
    }

    /// Kind of the line created by Return right after the title or a sub-heading.
    var kindAfterTitle: LineKind = .todo

    /// Shown while the sticker has no text at all.
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    /// Checkbox outlines get darker while the sticker is in edit mode (spec 4.6).
    var emphasizesMarkers = false {
        didSet {
            if emphasizesMarkers != oldValue { needsDisplay = true }
        }
    }

    /// The text storage is not retained by the TextKit objects, so the view keeps it.
    private var ownedStorage: NSTextStorage?
    private let uppercaseGenerator = UppercaseGlyphGenerator()
    private var isApplyingShortcut = false

    /// Keys pressed since the caret stood at the start of the line, by their place
    /// on the keyboard. This is how "[] " makes a task on a layout where those keys
    /// type letters (Russian: "хъ "). Empty as soon as anything else happens.
    private var keysSinceLineStart: [PhysicalKey] = []
    /// Start of the line `keysSinceLineStart` belongs to.
    private var keyTrackingLineStart = 0

    // MARK: Construction

    /// Creates the text view inside a scroll view, on an explicit TextKit 1 stack.
    static func makeScrollable() -> (scrollView: NSScrollView, textView: BlockTextView) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = BlockTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40), textContainer: container)
        textView.ownedStorage = storage
        layoutManager.delegate = textView.uppercaseGenerator
        textView.configure()

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        drawsBackground = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = false
        usesFontPanel = false
        usesRuler = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = Self.contentInset
        focusRingType = .none
        isEditable = false
        isSelectable = false
    }

    /// Breaks the reference cycle between the view and its text storage.
    func teardown() {
        blockDelegate = nil
        layoutManager?.delegate = nil
        ownedStorage = nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Content

    func load(_ document: EditorDocument) {
        keysSinceLineStart = []
        metas = document.metas
        textStorage?.setAttributedString(NSAttributedString(string: document.text))
        undoManager?.removeAllActions()
        restyle()
    }

    var document: EditorDocument {
        EditorDocument(text: string, metas: metas)
    }

    // MARK: Lines

    /// Character range of every line, without its trailing line break.
    private func lineRanges() -> [NSRange] {
        let text = string as NSString
        let length = text.length
        var ranges: [NSRange] = []
        var start = 0
        while start <= length {
            let found = text.range(of: "\n", options: [], range: NSRange(location: start, length: length - start))
            if found.location == NSNotFound {
                ranges.append(NSRange(location: start, length: length - start))
                break
            }
            ranges.append(NSRange(location: start, length: found.location - start))
            start = found.location + 1
        }
        return ranges
    }

    private func lineIndex(at location: Int) -> Int {
        let text = string as NSString
        let end = min(max(location, 0), text.length)
        var index = 0
        var position = 0
        while position < end {
            let found = text.range(of: "\n", options: [], range: NSRange(location: position, length: end - position))
            if found.location == NSNotFound { break }
            index += 1
            position = found.location + 1
        }
        return min(index, max(metas.count - 1, 0))
    }

    private var currentLine: Int {
        lineIndex(at: selectedRange().location)
    }

    // MARK: Keeping metas in step with the text

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else {
            return false
        }
        // `nil` means only attributes change.
        if let replacementString {
            metas = LineSplicer.splice(
                metas: metas,
                text: string,
                location: affectedCharRange.location,
                length: affectedCharRange.length,
                replacement: replacementString,
                kindAfterTitle: kindAfterTitle
            )
        }
        return true
    }

    override func didChangeText() {
        super.didChangeText()
        // Safety net: whatever path the edit took, never let the line count drift.
        metas = LineSplicer.repaired(metas, lineCount: LineSplicer.lineCount(of: string))
        if !isApplyingShortcut {
            applyShortcutAtCaret()
        }
        restyle()
        blockDelegate?.blockTextViewDidChangeContent(self)
    }

    /// Turns "[] ", "- ", "## " and friends typed at the start of a line into a block.
    private func applyShortcutAtCaret() {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        guard selection.length == 0 else { return }

        let line = lineIndex(at: selection.location)
        let ranges = lineRanges()
        guard line > 0, line < metas.count, line < ranges.count else { return }

        let range = ranges[line]
        let text = (string as NSString).substring(with: range)
        let match: BlockShortcut.Match
        if let byText = BlockShortcut.match(in: text),
           selection.location == range.location + byText.prefixLength {
            match = byText
        } else if keyTrackingLineStart == range.location,
                  let byKeys = BlockShortcut.match(physicalKeys: keysSinceLineStart),
                  selection.location == range.location + byKeys.prefixLength,
                  byKeys.prefixLength <= range.length {
            // The same keys on another layout: every key press gave one character.
            match = byKeys
        } else {
            return
        }
        keysSinceLineStart = []

        let prefix = NSRange(location: range.location, length: match.prefixLength)
        isApplyingShortcut = true
        defer { isApplyingShortcut = false }
        guard shouldChangeText(in: prefix, replacementString: "") else { return }
        storage.replaceCharacters(in: prefix, with: "")
        if line < metas.count {
            metas[line].convert(to: match.kind, done: match.done)
        }
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: 0))
    }

    // MARK: Styling

    func restyle() {
        guard let storage = textStorage else { return }
        metas = LineSplicer.repaired(metas, lineCount: LineSplicer.lineCount(of: string))

        let text = string as NSString
        let ranges = lineRanges()
        storage.beginEditing()
        for (index, range) in ranges.enumerated() where index < metas.count {
            // Include the line break so the paragraph style covers the whole paragraph.
            var full = range
            if NSMaxRange(range) < text.length {
                full.length += 1
            }
            guard full.length > 0 else { continue }
            storage.setAttributes(style.attributes(for: metas[index]), range: full)
        }
        storage.endEditing()

        syncTypingAttributes()
        // The empty line after a trailing line break is laid out from the typing
        // attributes, which were just updated; make TextKit lay it out again.
        if text.length > 0, text.character(at: text.length - 1) == 0x0A {
            layoutManager?.invalidateLayout(
                forCharacterRange: NSRange(location: text.length - 1, length: 1),
                actualCharacterRange: nil
            )
        }
        needsDisplay = true
    }

    /// Typing attributes decide how an empty line (and the line after the last
    /// line break) is laid out, so they must follow the line under the caret.
    private func syncTypingAttributes() {
        let line = currentLine
        guard metas.indices.contains(line) else { return }
        typingAttributes = style.attributes(for: metas[line])
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        if !stillSelectingFlag {
            syncTypingAttributes()
        }
    }

    // MARK: Measuring

    /// Height the text needs at the current width, including the insets.
    func fittingHeight() -> CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return ceil(used.height) + textContainerInset.height * 2
    }

    /// Number of lines that start below `y` (in the text view's coordinates) or are cut by it.
    func lineCount(notFittingAbove y: CGFloat) -> Int {
        var count = 0
        for range in lineRanges() {
            if let rect = firstLineRect(of: range), rect.maxY > y + 0.5 {
                count += 1
            }
        }
        return count
    }

    /// Rect of the first visual line of a paragraph, in view coordinates.
    private func firstLineRect(of range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)

        let length = (string as NSString).length
        var rect: NSRect
        if range.location < length {
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            // The empty line after the last line break lives in the extra line fragment.
            rect = layoutManager.extraLineFragmentRect
            guard rect.height > 0 else { return nil }
        }
        let origin = textContainerOrigin
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    // MARK: Markers

    private func markerBox(line: Int, ranges: [NSRange]) -> NSRect? {
        guard metas.indices.contains(line), ranges.indices.contains(line), metas[line].kind.hasMarker,
              let lineRect = firstLineRect(of: ranges[line])
        else { return nil }

        let size = BlockTextStyle.markerSize
        let textLeft = textContainerOrigin.x + style.textIndent(for: metas[line])
        return NSRect(
            x: textLeft - BlockTextStyle.markerGutter,
            y: (lineRect.midY - size / 2).rounded(),
            width: size,
            height: size
        )
    }

    /// Index of the task whose checkbox is under `point` (view coordinates).
    func todoLine(at point: NSPoint) -> Int? {
        let ranges = lineRanges()
        for line in metas.indices where metas[line].kind == .todo {
            if let box = markerBox(line: line, ranges: ranges), box.insetBy(dx: -5, dy: -4).contains(point) {
                return line
            }
        }
        return nil
    }

    func toggleDone(line: Int) {
        guard metas.indices.contains(line), metas[line].kind == .todo else { return }
        metas[line].toggleDone()
        restyle()
        blockDelegate?.blockTextViewDidChangeContent(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawMarkers()
        drawPlaceholder()
    }

    private func drawMarkers() {
        let ranges = lineRanges()
        for line in metas.indices {
            guard let box = markerBox(line: line, ranges: ranges) else { continue }
            switch metas[line].kind {
            case .todo:
                drawCheckbox(in: box, done: metas[line].done)
            case .bullet:
                drawBullet(in: box)
            case .title, .heading2, .text:
                break
            }
        }
    }

    private func drawCheckbox(in box: NSRect, done: Bool) {
        let alpha: CGFloat = done ? style.doneOpacity : (emphasizesMarkers ? 0.85 : 0.55)
        style.color.textColor(alpha: alpha).setStroke()

        let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
        outline.lineWidth = 1.25
        outline.stroke()

        guard done else { return }
        // The view is flipped: larger y is lower on screen.
        let check = NSBezierPath()
        check.move(to: NSPoint(x: box.minX + 3.3, y: box.midY + 0.4))
        check.line(to: NSPoint(x: box.minX + 5.7, y: box.maxY - 3.6))
        check.line(to: NSPoint(x: box.maxX - 3.1, y: box.minY + 3.8))
        check.lineWidth = 1.5
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.stroke()
    }

    private func drawBullet(in box: NSRect) {
        style.color.textColor(alpha: 0.7).setFill()
        let radius: CGFloat = 2
        let dot = NSRect(x: box.midX - radius, y: box.midY - radius, width: radius * 2, height: radius * 2)
        NSBezierPath(ovalIn: dot).fill()
    }

    private func drawPlaceholder() {
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let title = LineMeta.title()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.font(for: title),
            .foregroundColor: style.color.textColor(alpha: 0.35),
        ]
        let origin = textContainerOrigin
        let point = NSPoint(x: origin.x, y: origin.y + style.baselineOffset(for: title))
        (placeholder as NSString).draw(at: point, withAttributes: attributes)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        blockDelegate?.blockTextViewDidInteract(self)
        let point = convert(event.locationInWindow, from: nil)
        if let line = todoLine(at: point) {
            toggleDone(line: line)
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Keyboard

    private enum KeyCode {
        static let escape: UInt16 = 53
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
    }

    override func keyDown(with event: NSEvent) {
        blockDelegate?.blockTextViewDidInteract(self)

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])

        switch event.keyCode {
        case KeyCode.escape:
            blockDelegate?.blockTextViewDidRequestEndEditing(self)
            return
        case KeyCode.upArrow where flags == .option:
            moveCurrentLine(by: -1)
            return
        case KeyCode.downArrow where flags == .option:
            moveCurrentLine(by: 1)
            return
        default:
            trackPhysicalKey(event.keyCode, flags: flags)
            super.keyDown(with: event)
        }
    }

    /// Remembers the key for layout-independent shortcuts (see `keysSinceLineStart`).
    /// The run is kept only while every key since the start of the line added
    /// exactly one character at the caret.
    private func trackPhysicalKey(_ keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let selection = selectedRange()
        let line = lineIndex(at: selection.location)
        let ranges = lineRanges()
        guard selection.length == 0, line > 0, line < ranges.count,
              flags.subtracting(.shift).isEmpty, !hasMarkedText()
        else {
            keysSinceLineStart = []
            return
        }
        let lineStart = ranges[line].location
        if selection.location == lineStart {
            keysSinceLineStart = []
            keyTrackingLineStart = lineStart
        } else if keysSinceLineStart.isEmpty
            || keyTrackingLineStart != lineStart
            || selection.location != lineStart + keysSinceLineStart.count {
            keysSinceLineStart = []
            return
        }
        keysSinceLineStart.append(PhysicalKey(code: keyCode, shift: flags.contains(.shift)))
    }

    /// Stickflow is an agent app without a main menu, so the usual Edit-menu
    /// shortcuts have to be handled here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            return super.performKeyEquivalent(with: event)
        }
        blockDelegate?.blockTextViewDidInteract(self)

        if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnter {
            toggleDone(line: currentLine)
            return true
        }

        let shift = flags.contains(.shift)
        switch event.characters?.lowercased() ?? "" {
        case "c":
            copy(nil)
        case "x":
            cut(nil)
        case "v":
            pasteAsPlainText(nil)
        case "a":
            selectAll(nil)
        case "z":
            if shift {
                undoManager?.redo()
            } else {
                undoManager?.undo()
            }
        case "=", "+":
            blockDelegate?.blockTextView(self, didRequestFontSizeChange: 1)
        case "-", "_":
            blockDelegate?.blockTextView(self, didRequestFontSizeChange: -1)
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let line = currentLine
        let ranges = lineRanges()
        if selection.length == 0, line > 0, line < ranges.count, line < metas.count, ranges[line].length == 0 {
            // Return on an empty item: one level out, then plain text (spec 4.8).
            if metas[line].indent > 0 {
                metas[line].shiftIndent(by: -1)
                restyleAndNotify()
                return
            }
            if metas[line].kind != .text {
                metas[line].convert(to: .text)
                restyleAndNotify()
                return
            }
        }
        super.insertNewline(sender)
    }

    /// Shift-Return would insert a line separator that is not a paragraph break;
    /// a block is always a single paragraph, so treat it as Return.
    override func insertLineBreak(_ sender: Any?) {
        insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        shiftIndentAtCaret(by: 1)
    }

    override func insertBacktab(_ sender: Any?) {
        shiftIndentAtCaret(by: -1)
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        let line = currentLine
        let ranges = lineRanges()
        if selection.length == 0, line > 0, line < ranges.count, line < metas.count,
           selection.location == ranges[line].location,
           metas[line].kind != .text || metas[line].indent > 0 {
            // Backspace at the start: first the block becomes plain text, the next press joins lines.
            metas[line].convert(to: .text)
            metas[line].indent = 0
            restyleAndNotify()
            return
        }
        super.deleteBackward(sender)
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard isEditable, let pasted = NSPasteboard.general.string(forType: .string) else { return }
        let normalized = EditorDocument.normalizedLineBreaks(pasted)
        insertText(normalized, replacementRange: selectedRange())
    }

    private func shiftIndentAtCaret(by delta: Int) {
        let line = currentLine
        guard line > 0, metas.indices.contains(line) else { return }
        let before = metas[line]
        metas[line].shiftIndent(by: delta)
        guard metas[line] != before else { return }
        restyleAndNotify()
    }

    /// ⌥↑ / ⌥↓: swaps the line under the caret with its neighbour. The title stays first.
    private func moveCurrentLine(by delta: Int) {
        guard let storage = textStorage else { return }
        let line = currentLine
        let target = line + delta
        var lines = (string as NSString).components(separatedBy: "\n")
        guard line > 0, target > 0, target < metas.count, lines.count == metas.count else { return }

        let column = selectedRange().location - lineRanges()[line].location
        lines.swapAt(line, target)
        metas.swapAt(line, target)

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: lines.joined(separator: "\n"))
        // This rewrite bypasses the undo stack; older entries would point at wrong ranges.
        undoManager?.removeAllActions()
        restyle()

        let moved = lineRanges()[target]
        setSelectedRange(NSRange(location: moved.location + min(max(column, 0), moved.length), length: 0))
        blockDelegate?.blockTextViewDidChangeContent(self)
    }

    private func restyleAndNotify() {
        restyle()
        blockDelegate?.blockTextViewDidChangeContent(self)
    }
}
