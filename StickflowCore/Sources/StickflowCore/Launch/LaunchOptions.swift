// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation

/// What the command line asks for (spec 17.4).
public struct LaunchOptions: Equatable, Sendable {
    /// `--ui-testing`: memory-only database and settings, no animations, a fixed
    /// date and a fixed screen layout, so that every run starts the same.
    public var isUITesting = false
    /// `--seed=<fixture>`: stickers to start with.
    public var seed: SeedFixture?
    /// A `--seed` value that names no fixture; kept so the app can say so.
    public var unknownSeed: String?
    /// `--self-check <directory>`: run the scripted check and write its report there (debug builds).
    public var selfCheckDirectory: String?

    public init() {}

    /// - Parameter arguments: the process arguments; the program path, if present, is ignored.
    public init(arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--ui-testing" {
                isUITesting = true
            } else if argument.hasPrefix("--seed=") {
                let name = String(argument.dropFirst("--seed=".count))
                if let fixture = SeedFixture(rawValue: name) {
                    seed = fixture
                } else {
                    unknownSeed = name
                }
            } else if argument == "--self-check", index + 1 < arguments.count {
                selfCheckDirectory = arguments[index + 1]
                index += 1
            }
            index += 1
        }
    }
}

/// Ready-made stickers for UI tests, snapshots and demos (`--seed=<name>`).
public enum SeedFixture: String, CaseIterable, Sendable {
    /// The sticker drawn in spec 4.6: a heading, tasks, a nested point, one task done.
    case plan
    /// More lines than fit into the tallest sticker.
    case long
    /// Two stickers, to see how they sit together.
    case pair

    /// - Parameter now: used for every date in the fixture, so that it is reproducible.
    public func stickers(now: Date) -> [Sticker] {
        switch self {
        case .plan:
            [Self.planSticker(now: now)]
        case .long:
            [Self.longSticker(now: now)]
        case .pair:
            [Self.planSticker(now: now), Self.longSticker(now: now.addingTimeInterval(60))]
        }
    }

    private static func planSticker(now: Date) -> Sticker {
        Sticker(
            id: fixedID(1),
            title: "План на день",
            blocks: [
                Block(id: fixedID(11), kind: .heading2, text: "Кошелёк"),
                Block(id: fixedID(12), kind: .todo, text: "Доделать экран"),
                Block(id: fixedID(13), kind: .bullet, text: "пустые состояния", indent: 1),
                Block(id: fixedID(14), kind: .todo, text: "Созвон с разработкой 15:00", done: true, doneAt: now),
                Block(id: fixedID(15), kind: .todo, text: "Написать пост"),
            ],
            createdAt: now,
            stuckAt: now
        )
    }

    private static func longSticker(now: Date) -> Sticker {
        Sticker(
            id: fixedID(2),
            title: "Длинный список",
            blocks: (1...16).map { number in
                Block(id: fixedID(100 + number), kind: .todo, text: "Задача номер \(number)")
            },
            createdAt: now,
            stuckAt: now
        )
    }

    /// Stable identifiers, so that two runs produce the same data.
    private static func fixedID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number)) ?? UUID()
    }
}
