import Foundation
import XCTest
@testable import VoiceInk

@MainActor
final class HaasModelPreparationTests: XCTestCase {
    func testReadyRechecksDeletedOrReplacedModelWithoutNetwork() async throws {
        for replaceModel in [false, true] {
            let fixture = try HaasModelAssetFixture()
            defer { fixture.cleanUp() }
            let suite = "HaasPreparationTests-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let preparation = HaasModelPreparation(
                settings: HaasSettingsStore(defaults: defaults), assets: fixture.assets)

            preparation.prepare()
            try await waitUntil { !preparation.isWorking }
            XCTAssertTrue(preparation.isReady)
            let requestCount = fixture.requestCount
            XCTAssertEqual(requestCount, 2)

            let modelURL = fixture.cacheURL(.recognition)
            if replaceModel {
                try Data("xyz".utf8).write(to: modelURL, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: modelURL)
            }

            preparation.refreshIfNeeded()
            XCTAssertFalse(preparation.isReady)
            guard case .failed = preparation.state else {
                return XCTFail("A missing or changed model must expose an explicit retry")
            }
            XCTAssertFalse(preparation.isWorking)
            XCTAssertEqual(fixture.requestCount, requestCount)

            preparation.refreshIfNeeded()
            XCTAssertFalse(preparation.isWorking)
            XCTAssertEqual(fixture.requestCount, requestCount)

            preparation.prepare()
            try await waitUntil { !preparation.isWorking }
            XCTAssertTrue(preparation.isReady)
            XCTAssertEqual(fixture.requestCount, requestCount + 1)
        }
    }

    func testCancelledLaunchDoesNotRestartOnPassiveRefresh() async throws {
        let fixture = try HaasModelAssetFixture(largeModel: true)
        defer { fixture.cleanUp() }
        fixture.respond(.recognition, body: fixture.modelBody, chunkDelay: 0.02)
        let suite = "HaasPreparationTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preparation = HaasModelPreparation(
            settings: HaasSettingsStore(defaults: defaults), assets: fixture.assets)

        preparation.startAtLaunchIfNeeded()
        try await waitUntil { (preparation.progress?.completedBytes ?? 0) > 0 }
        preparation.cancel()
        try await waitUntil { !preparation.isWorking }
        guard case .cancelled = preparation.state else {
            return XCTFail("A cancelled preparation must remain cancelled")
        }
        let requestCount = fixture.requestCount

        preparation.refreshIfNeeded()
        preparation.startAtLaunchIfNeeded()
        XCTAssertFalse(preparation.isWorking)
        XCTAssertFalse(preparation.isReady)
        XCTAssertEqual(fixture.requestCount, requestCount)
        XCTAssertTrue(fixture.partials.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Preparation did not reach the expected observable state")
    }
}
