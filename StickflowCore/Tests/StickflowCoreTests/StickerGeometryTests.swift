// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import CoreGraphics
import XCTest
@testable import StickflowCore

final class StickerGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    func testDefaultAnchorSitsBelowToolbars() {
        let anchor = StickerGeometry.defaultTopRight(visibleFrame: screen, insetRight: 20, insetTop: 112)
        XCTAssertEqual(anchor, CGPoint(x: 1420, y: 763))
    }

    func testClampKeepsFrameInside() {
        let frame = CGRect(x: 1400, y: -30, width: 232, height: 120)
        let clamped = StickerGeometry.clamped(frame, within: screen)
        XCTAssertEqual(clamped, CGRect(x: 1208, y: 0, width: 232, height: 120))
    }

    func testClampAlignsOversizedFrameToTopLeft() {
        let small = CGRect(x: 100, y: 100, width: 200, height: 100)
        let frame = CGRect(x: 150, y: 150, width: 400, height: 300)
        let clamped = StickerGeometry.clamped(frame, within: small)
        XCTAssertEqual(clamped.minX, small.minX)
        XCTAssertEqual(clamped.maxY, small.maxY)
    }

    func testSnapsToScreenEdgeWithinDistance() {
        let frame = CGRect(x: 1200, y: 400, width: 232, height: 120) // maxX = 1432, 8 pt from the edge
        let snapped = StickerGeometry.snapped(frame, within: screen, others: [], distance: 12)
        XCTAssertEqual(snapped.maxX, screen.maxX)
        XCTAssertEqual(snapped.minY, 400)
    }

    func testDoesNotSnapBeyondDistance() {
        let frame = CGRect(x: 1100, y: 400, width: 232, height: 120)
        let snapped = StickerGeometry.snapped(frame, within: screen, others: [], distance: 12)
        XCTAssertEqual(snapped, frame)
    }

    func testSnapsNextToAnotherSticker() {
        let other = CGRect(x: 1000, y: 400, width: 232, height: 120)
        // 5 pt gap to the right of `other`, and 4 pt lower.
        let frame = CGRect(x: 1237, y: 396, width: 100, height: 120)
        let snapped = StickerGeometry.snapped(frame, within: screen, others: [other], distance: 12)
        XCTAssertEqual(snapped.minX, other.maxX)
        XCTAssertEqual(snapped.maxY, other.maxY)
    }

    func testIgnoresStickersFarAway() {
        let other = CGRect(x: 100, y: 100, width: 232, height: 120)
        let frame = CGRect(x: 105, y: 600, width: 232, height: 120)
        let snapped = StickerGeometry.snapped(frame, within: screen, others: [other], distance: 12)
        XCTAssertEqual(snapped, frame, "edges only attract when the stickers are near each other")
    }

    func testPicksTheNearestEdge() {
        let other = CGRect(x: 500, y: 300, width: 200, height: 100)
        // Left edge 3 pt from other's left edge, right edge 10 pt from other's right edge.
        let frame = CGRect(x: 503, y: 320, width: 207, height: 60)
        let snapped = StickerGeometry.snapped(frame, within: screen, others: [other], distance: 12)
        XCTAssertEqual(snapped.minX, 500)
    }
}
