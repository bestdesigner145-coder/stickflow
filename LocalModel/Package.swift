// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

/// The model that takes dictation apart inside the app (spec 18.10): llama.cpp
/// with Metal, from the project's own release build. The version is pinned:
/// the C API changes from release to release.
let package = Package(
    name: "StickflowLocalModel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalModel", targets: ["LocalModel"]),
        .executable(name: "stickflow-report", targets: ["stickflow-report"]),
    ],
    dependencies: [
        .package(path: "../StickflowCore"),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12465/llama-b12465-xcframework.zip",
            checksum: "f3693af1f8aba3da5b1a1c003b03c28f542ee244fe17c85f640fb939a8a060d8"
        ),
        .target(
            name: "LocalModel",
            dependencies: ["llama", .product(name: "StickflowCore", package: "StickflowCore")]
        ),
        // The report that chooses the model (spec 8.6, 18.10 A5); CI runs it.
        .executableTarget(
            name: "stickflow-report",
            dependencies: ["LocalModel", .product(name: "StickflowCore", package: "StickflowCore")],
            path: "Sources/StickflowReport"
        ),
    ]
)
