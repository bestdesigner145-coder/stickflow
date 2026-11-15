// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// Fits a short label into a narrow box by its longest word, so that a line
/// never breaks inside a word (the pad's label, spec 4.2).
public enum LabelFit {
    /// The words a label may be broken between.
    public static func words(of label: String) -> [String] {
        label.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\u{00A0}" }).map(String.init)
    }

    /// The font size at which the widest word fits `available`, in half-point steps,
    /// never above `base` and never below `minimum`.
    /// - Parameter widestWord: width of the widest word at the `base` size.
    public static func fontSize(base: Double, minimum: Double, widestWord: Double, available: Double) -> Double {
        guard widestWord > 0, available > 0, widestWord > available else { return base }
        let fitted = (base * available / widestWord * 2).rounded(.down) / 2
        return min(base, max(minimum, fitted))
    }
}
