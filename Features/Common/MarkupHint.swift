// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import Carbon.HIToolbox

/// The one grey line under the placeholder of an empty draft and an empty
/// sticker (spec 18.5): how to start a heading, a point and a task. On a
/// Russian layout the same keys type "№№" and "хъ", so the line shows those.
/// It goes away with the first character.
@MainActor
enum MarkupHint {
    /// Fixes the layout for snapshots and the self-check; `nil` asks the system.
    static var forcedRussianLayout: Bool?

    private static let fontSize: CGFloat = 10.5
    private static let views = NSHashTable<NSView>.weakObjects()
    private static var isObserving = false

    /// The keyboard is typing Russian right now.
    static var isRussianLayout: Bool {
        if let forcedRussianLayout { return forcedRussianLayout }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return false }
        let languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as NSArray as? [String]
        return languages?.first == "ru"
    }

    static var text: String {
        isRussianLayout ? L10n.markupHint(heading: "№№", task: "хъ") : L10n.markupHint(heading: "##", task: "[]")
    }

    private static func attributed(color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
        ])
    }

    /// Height the line takes at `width`; it wraps on a narrow sheet.
    static func height(fittingWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let rect = attributed(color: .labelColor).boundingRect(
            with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin]
        )
        return ceil(rect.height)
    }

    /// Draws the line with its top left corner at `origin` (flipped coordinates).
    static func draw(at origin: NSPoint, width: CGFloat, color: NSColor) {
        guard width > 0 else { return }
        let rect = NSRect(x: origin.x, y: origin.y, width: width, height: height(fittingWidth: width))
        attributed(color: color).draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    /// Redraws `view` whenever the keyboard layout changes.
    static func follow(_ view: NSView) {
        views.add(view)
        guard !isObserving else { return }
        isObserving = true
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        // Kept for the life of the app, like the hint itself.
        _ = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for view in views.allObjects {
                    view.needsDisplay = true
                }
            }
        }
    }
}
