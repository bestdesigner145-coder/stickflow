// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// Which build is running, for the menu: when the executable was made and,
/// when the build was told, the commit it was made from. Before there are
/// releases this is the only way to tell a fresh build from a stale one.
enum BuildStamp {
    /// "17.11 11:40 · 78793aa", or only the time when the commit is not known.
    static var text: String {
        var parts: [String] = []
        if let url = Bundle.main.executableURL,
           let made = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "dd.MM HH:mm"
            parts.append(formatter.string(from: made))
        }
        if let commit = Bundle.main.object(forInfoDictionaryKey: "StickflowCommit") as? String, !commit.isEmpty {
            parts.append(commit)
        }
        return parts.joined(separator: " · ")
    }
}
