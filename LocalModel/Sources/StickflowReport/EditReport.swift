// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
import LocalModel
import StickflowCore

/// `stickflow-report --edits <model.gguf>`: voice commands for a sticker
/// (spec 18.22) through the built-in model, on a sticker the prompt's examples
/// do not show. Each case says what a right answer does.
enum EditReport {
    struct Case: Sendable {
        let said: String
        let right: @Sendable (StickerEdit) -> Bool
    }

    static let blocks = [
        Block(kind: .todo, text: "Обновить экран пополнения"),
        Block(kind: .todo, text: "Созвон с ЮMoney 11:00"),
        Block(kind: .bullet, text: "Проверить лимиты по карте"),
        Block(kind: .todo, text: "Написать требования к выписке"),
    ]

    static let cases: [Case] = [
        Case(said: "добавь в пункт про выписку: формат PDF и CSV") {
            $0.operations.contains {
                if case .addChildren(4, _) = $0 {
                    true
                } else {
                    false
                }
            }
        },
        Case(said: "отметь созвон") { $0.operations == [.check(target: 2)] },
        Case(said: "сделай пункт про лимиты задачей") { $0.operations == [.setType(target: 3, type: .task)] },
        Case(said: "удали пункт про пополнение") { $0.operations == [.delete(target: 1)] },
        Case(said: "перенеси выписку наверх") { $0.operations == [.move(target: 4, position: 1)] },
        Case(said: "переименуй стикер в Виртуальная карта") {
            $0.operations.contains {
                if case let .rename(title) = $0 {
                    title.contains("Виртуальн")
                } else {
                    false
                }
            }
        },
        Case(said: "ещё надо обновить тексты в онбординге") {
            !$0.isCommand && !$0.operations.isEmpty
        },
        Case(said: "отметь тот пункт") { $0.unsure || $0.operations.isEmpty },
    ]

    static func run(model path: String) async -> String {
        var settings = LlamaSettings()
        if let layers = ProcessInfo.processInfo.environment["STICKFLOW_GPU_LAYERS"].flatMap({ Int32($0) }) {
            settings.gpuLayers = layers
        }
        let structurer = LocalStructurer(runner: LlamaRunner(file: URL(fileURLWithPath: path), settings: settings), displayName: "model")
        var rows = ["| Сказано | Ответ | Верно | Время |", "|---|---|---|---|"]
        var right = 0
        for item in cases {
            let start = Date()
            let request = StickerEditRequest(title: "Кошелёк", blocks: blocks, text: item.said)
            let row: String
            do {
                let edit = try await structurer.edit(request)
                let ok = item.right(edit)
                if ok { right += 1 }
                row = "| \(item.said) | \(describe(edit)) | \(ok ? "да" : "**нет**") | \(Int(Date().timeIntervalSince(start))) с |"
            } catch {
                row = "| \(item.said) | ошибка: \(error) | **нет** | \(Int(Date().timeIntervalSince(start))) с |"
            }
            FileHandle.standardError.write(Data((row + "\n").utf8))
            rows.append(row)
        }
        return "## Голосовые команды (ТЗ 18.22): \(right) из \(cases.count)\n\n"
            + "Стикер:\n\n```\n\(StickerEdit.numberedLines(title: "Кошелёк", blocks: blocks))\n```\n\n"
            + rows.joined(separator: "\n") + "\n"
    }

    static func describe(_ edit: StickerEdit) -> String {
        if edit.unsure { return "не уверена" }
        return edit.operations.map { operation in
            switch operation {
            case let .addItems(sections): "add_items(\(sections.flatMap(\.items).map(\.text).joined(separator: "; ")))"
            case let .addChildren(target, items): "add_children(\(target): \(items.joined(separator: "; ")))"
            case let .setType(target, type): "set_type(\(target), \(type.rawValue))"
            case let .check(target): "check(\(target))"
            case let .uncheck(target): "uncheck(\(target))"
            case let .delete(target): "delete(\(target))"
            case let .move(target, position): "move(\(target) → \(position))"
            case let .rename(title): "rename(\(title))"
            case let .editText(target, text): "edit_text(\(target): \(text))"
            }
        }.joined(separator: ", ")
    }
}
