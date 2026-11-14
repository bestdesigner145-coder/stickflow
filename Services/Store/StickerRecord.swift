// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import Foundation
import GRDB
import StickflowCore

/// Database row for a `Sticker`. Nested values (blocks, placement) are stored as JSON text.
struct StickerRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "sticker"

    var id: String
    var title: String
    var blocks: String
    var status: String
    var color: String
    var placement: String?
    var source: String
    var rawInput: String?
    var createdAt: Date
    var updatedAt: Date
    var stuckAt: Date?
    var peeledAt: Date?
    var deletedAt: Date?
}

enum StickerRecordError: Error, Equatable {
    case invalidIdentifier(String)
    case invalidText(column: String)
}

extension StickerRecord {
    init(_ sticker: Sticker) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        id = sticker.id.uuidString
        title = sticker.title
        blocks = try Self.text(from: encoder.encode(sticker.blocks), column: "blocks")
        status = sticker.status.rawValue
        color = sticker.color.rawValue
        if let stickerPlacement = sticker.placement {
            placement = try Self.text(from: encoder.encode(stickerPlacement), column: "placement")
        } else {
            placement = nil
        }
        source = sticker.source.rawValue
        rawInput = sticker.rawInput
        createdAt = sticker.createdAt
        updatedAt = sticker.updatedAt
        stuckAt = sticker.stuckAt
        peeledAt = sticker.peeledAt
        deletedAt = sticker.deletedAt
    }

    /// Rebuilds the model. Unknown enum values fall back to safe defaults so a
    /// database written by a newer version does not make the app unusable.
    func sticker() throws -> Sticker {
        guard let uuid = UUID(uuidString: id) else {
            throw StickerRecordError.invalidIdentifier(id)
        }
        let decoder = JSONDecoder()
        let decodedBlocks = try decoder.decode([Block].self, from: Data(blocks.utf8))
        let decodedPlacement = try placement.map { try decoder.decode(Placement.self, from: Data($0.utf8)) }

        return Sticker(
            id: uuid,
            title: title,
            blocks: decodedBlocks,
            status: Sticker.Status(rawValue: status) ?? .draft,
            color: PaperColor(stored: color) ?? .default,
            placement: decodedPlacement,
            source: Sticker.Source(rawValue: source) ?? .typed,
            rawInput: rawInput,
            createdAt: createdAt,
            updatedAt: updatedAt,
            stuckAt: stuckAt,
            peeledAt: peeledAt,
            deletedAt: deletedAt
        )
    }

    private static func text(from data: Data, column: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw StickerRecordError.invalidText(column: column)
        }
        return text
    }
}
