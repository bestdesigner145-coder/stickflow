// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

/// StickflowCore holds everything that must not depend on AppKit:
/// data models, block-editing rules and geometry. A future iOS app shares it.
let package = Package(
    name: "StickflowCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "StickflowCore", targets: ["StickflowCore"]),
    ],
    targets: [
        .target(name: "StickflowCore"),
        .testTarget(name: "StickflowCoreTests", dependencies: ["StickflowCore"]),
    ]
)
