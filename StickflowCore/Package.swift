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
        // The report on structuring by meaning (spec 8.6, 18.3); see scripts/structure-report.sh.
        .executableTarget(name: "stickflow-report", dependencies: ["StickflowCore"], path: "Sources/StickflowReport"),
        .testTarget(
            name: "StickflowCoreTests",
            dependencies: ["StickflowCore"],
            resources: [.copy("StructuringFixtures")]
        ),
    ]
)
