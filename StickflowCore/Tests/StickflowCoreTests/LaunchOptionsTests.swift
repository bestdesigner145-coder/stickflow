// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

@testable import StickflowCore
import XCTest

final class LaunchOptionsTests: XCTestCase {
    func testPlainLaunch() {
        let options = LaunchOptions(arguments: ["/Applications/Stickflow.app/Contents/MacOS/Stickflow"])
        XCTAssertEqual(options, LaunchOptions())
        XCTAssertFalse(options.isUITesting)
        XCTAssertNil(options.seed)
    }

    func testUITestingWithASeed() {
        let options = LaunchOptions(arguments: ["Stickflow", "--ui-testing", "--seed=long"])
        XCTAssertTrue(options.isUITesting)
        XCTAssertEqual(options.seed, .long)
        XCTAssertNil(options.unknownSeed)
    }

    func testUnknownSeedIsReportedNotGuessed() {
        let options = LaunchOptions(arguments: ["Stickflow", "--seed=nope"])
        XCTAssertNil(options.seed)
        XCTAssertEqual(options.unknownSeed, "nope")
    }

    func testSelfCheckTakesTheNextArgumentAsItsDirectory() {
        let options = LaunchOptions(arguments: ["Stickflow", "--self-check", "/tmp/out", "--ui-testing"])
        XCTAssertEqual(options.selfCheckDirectory, "/tmp/out")
        XCTAssertTrue(options.isUITesting)

        XCTAssertNil(LaunchOptions(arguments: ["Stickflow", "--self-check"]).selfCheckDirectory)
    }

    func testDemoTakesASoundFileAndAPlaceForTheModels() {
        let options = LaunchOptions(arguments: ["Stickflow", "--demo", "/tmp/said.wav", "--models-root", "/tmp/models", "--cpu-only"])
        XCTAssertEqual(options.demoAudio, "/tmp/said.wav")
        XCTAssertTrue(options.isCPUOnly)
        XCTAssertEqual(options.modelsRoot, "/tmp/models")
        XCTAssertNil(LaunchOptions(arguments: ["Stickflow", "--demo"]).demoAudio, "a flag without its file is ignored")
    }

    func testSeedsAreReproducible() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for fixture in SeedFixture.allCases {
            XCTAssertEqual(fixture.stickers(now: now), fixture.stickers(now: now), "\(fixture)")
            XCTAssertFalse(fixture.stickers(now: now).isEmpty)
        }
        XCTAssertEqual(SeedFixture.pair.stickers(now: now).count, 2)

        let plan = SeedFixture.plan.stickers(now: now)[0]
        XCTAssertEqual(plan.title, "План на день")
        XCTAssertEqual(plan.taskCount, TaskCount(done: 1, total: 3))
        XCTAssertEqual(plan.createdAt, now)

        let long = SeedFixture.long.stickers(now: now)[0]
        XCTAssertEqual(long.blocks.count, 16)
        XCTAssertEqual(Set(long.blocks.map(\.id)).count, 16, "every block has its own id")
    }
}
