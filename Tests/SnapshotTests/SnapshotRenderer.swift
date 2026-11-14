// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

import AppKit
import SnapshotTesting

/// What every snapshot test shares.
@MainActor
enum SnapshotRenderer {
    /// Small differences in text rendering between machines are not regressions.
    static let strategy = Snapshotting<NSImage, NSImage>.image(precision: 0.98, perceptualPrecision: 0.98)

    /// Draws the view into a bitmap with one pixel per point, so that the picture
    /// has the same size on a Retina display and on a CI runner.
    static func image(of view: NSView) -> NSImage {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let size = view.bounds.size
        let image = NSImage(size: size)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width.rounded()),
            pixelsHigh: Int(size.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return image }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        image.addRepresentation(bitmap)
        return image
    }
}
