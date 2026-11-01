import Foundation
import XCTest
@testable import VoiceInk

final class HaasRecoveryStoreTests: XCTestCase {
    @MainActor
    func testSessionCheckpointSurvivesRestartAndLoadDoesNotWrite() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        var state = try store.load()
        var activeLedger = HaasSegmentLedger()
        activeLedger.append(id: "posted", text: "VoiceInk ")
        activeLedger.setDisposition(.posted, for: "posted")
        activeLedger.append(id: "interrupted", text: "Haas")
        activeLedger.setDisposition(.posting, for: "interrupted")
        state.active = HaasRecoveryRecord(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            transcriptionID: UUID(), ledger: activeLedger, message: "active"
        )
        var archiveLedger = HaasSegmentLedger()
        archiveLedger.append(id: "older", text: "Amazon Bedrock")
        state.archives = [HaasRecoveryRecord(id: UUID(), createdAt: nil, ledger: archiveLedger, message: "older")]
        try store.save(state)
        let checkpoint = try Data(contentsOf: fixture.fileURL)

        let restartedStore = fixture.store()
        let recovered = try restartedStore.load()
        XCTAssertEqual(recovered.active?.id, state.active?.id)
        XCTAssertEqual(recovered.active?.createdAt, state.active?.createdAt)
        XCTAssertEqual(recovered.active?.transcriptionID, state.active?.transcriptionID)
        XCTAssertEqual(recovered.active?.ledger.fullText, "VoiceInk Haas")
        XCTAssertEqual(recovered.active?.ledger.uncertainText, "Haas")
        XCTAssertEqual(recovered.archives, state.archives)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), checkpoint)

        try restartedStore.save(recovered)
        let persisted = try JSONDecoder().decode(HaasRecoveryState.self, from: Data(contentsOf: fixture.fileURL))
        XCTAssertEqual(persisted.active?.ledger.segments.map(\.disposition), [.posted, .uncertain])
    }

    @MainActor
    func testLegacyMigrationCommitsBeforeCleanupAndDoesNotImportTwice() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.defaults.set(Self.legacyPayload, forKey: "HaasPendingInput.v1")
        let store = fixture.store()
        var migrated = try store.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertEqual(fixture.defaults.data(forKey: "HaasPendingInput.v1"), Self.legacyPayload)
        let archive = try XCTUnwrap(migrated.archives.first)
        XCTAssertEqual(migrated.archives.count, 1)
        XCTAssertNil(archive.createdAt)
        XCTAssertNil(archive.transcriptionID)
        XCTAssertEqual(archive.ledger.pendingText, "Amazon Bedrock")
        XCTAssertEqual(archive.ledger.uncertainText, "JiHAN Prime")
        XCTAssertEqual(archive.ledger.segments.map(\.disposition), [.uncertain, .pending])
        XCTAssertEqual(migrated.legacyMigrationFingerprint?.count, 64)
        migrated.active = HaasRecoveryRecord(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        try store.save(migrated)
        XCTAssertNil(fixture.defaults.object(forKey: "HaasPendingInput.v1"))

        // Model a restart after the JSON committed but before defaults cleanup reached disk.
        fixture.defaults.set(Self.legacyPayload, forKey: "HaasPendingInput.v1")
        let restartedStore = fixture.store()
        let restarted = try restartedStore.load()
        XCTAssertEqual(restarted, migrated)
        XCTAssertEqual(restarted.archives.first?.id, archive.id)
        XCTAssertEqual(fixture.defaults.data(forKey: "HaasPendingInput.v1"), Self.legacyPayload)
        try restartedStore.save(restarted)
        XCTAssertNil(fixture.defaults.object(forKey: "HaasPendingInput.v1"))
    }

    @MainActor
    func testCleanupReappearanceOnlyAllowsAlreadyMigratedPayload() throws {
        let changedLegacy = Data(#"{"segments":[{"id":"later","text":"unmigrated input","disposition":"pending"}]}"#.utf8)
        for (reappearingData, changed) in [(Self.legacyPayload, false), (changedLegacy, true)] {
            let fixture = try Fixture()
            let suiteName = "HaasRecoveryCleanupTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(LegacyReappearingDefaults(suiteName: suiteName))
            defer {
                defaults.removePersistentDomain(forName: suiteName)
                fixture.remove()
            }
            defaults.set(Self.legacyPayload, forKey: "HaasPendingInput.v1")
            defaults.replacementAfterRemoval = reappearingData
            let store = HaasRecoveryStore(fileURL: fixture.fileURL, legacyDefaults: defaults)
            let candidate = try store.load()

            if changed {
                XCTAssertThrowsError(try store.save(candidate)) { error in
                    guard case .legacyChanged = error as? HaasRecoveryError else {
                        return XCTFail("Expected changed legacy data after cleanup, received \(error)")
                    }
                }
            } else {
                try store.save(candidate)
            }
            XCTAssertEqual(defaults.data(forKey: "HaasPendingInput.v1"), reappearingData)
            let committed = try Data(contentsOf: fixture.fileURL)
            XCTAssertEqual(try JSONDecoder().decode(HaasRecoveryState.self, from: committed), candidate)

            if changed {
                XCTAssertThrowsError(try store.save(candidate)) { error in
                    guard case .loadRequired = error as? HaasRecoveryError else {
                        return XCTFail("Changed cleanup data must invalidate the loaded baseline, received \(error)")
                    }
                }
                XCTAssertEqual(defaults.data(forKey: "HaasPendingInput.v1"), changedLegacy)
                XCTAssertThrowsError(try store.load()) { error in
                    guard case .legacyChanged = error as? HaasRecoveryError else {
                        return XCTFail("Reload must reject an unmigrated fingerprint, received \(error)")
                    }
                }
                XCTAssertEqual(defaults.data(forKey: "HaasPendingInput.v1"), changedLegacy)
                XCTAssertEqual(try Data(contentsOf: fixture.fileURL), committed)
            } else {
                try store.save(candidate)
                XCTAssertNil(defaults.object(forKey: "HaasPendingInput.v1"))
                XCTAssertEqual(try store.load(), candidate)
            }
        }
    }

    @MainActor
    func testInvalidNewFileNeverFallsBackToLegacyOrGetsOverwritten() throws {
        let payloads: [(Data, Int?)] = [
            (Data("{broken".utf8), nil),
            (Data(#"{"version":99,"archives":[]}"#.utf8), 99),
            (Data(#"{"archives":[]}"#.utf8), nil),
        ]
        for (payload, unsupportedVersion) in payloads {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try payload.write(to: fixture.fileURL)
            fixture.defaults.set(Self.legacyPayload, forKey: "HaasPendingInput.v1")
            let store = fixture.store()
            XCTAssertThrowsError(try store.load()) { error in
                if let unsupportedVersion {
                    guard case .unsupportedVersion(let actual) = error as? HaasRecoveryError else {
                        return XCTFail("Expected unsupported version, received \(error)")
                    }
                    XCTAssertEqual(actual, unsupportedVersion)
                } else {
                    guard case .unreadableState = error as? HaasRecoveryError else {
                        return XCTFail("Expected unreadable state, received \(error)")
                    }
                }
            }
            XCTAssertThrowsError(try store.save(HaasRecoveryState()))
            XCTAssertEqual(try Data(contentsOf: fixture.fileURL), payload)
            XCTAssertEqual(fixture.defaults.data(forKey: "HaasPendingInput.v1"), Self.legacyPayload)
        }
    }

    @MainActor
    func testMalformedAndNonDataLegacyValuesArePreserved() throws {
        let invalidValues: [Any] = [Data("{broken".utf8), "not Data"]
        for value in invalidValues {
            let fixture = try Fixture()
            defer { fixture.remove() }
            fixture.defaults.set(value, forKey: "HaasPendingInput.v1")
            let store = fixture.store()
            XCTAssertThrowsError(try store.load()) { error in
                guard case .unreadableLegacy = error as? HaasRecoveryError else {
                    return XCTFail("Expected unreadable legacy state, received \(error)")
                }
            }
            XCTAssertThrowsError(try store.save(HaasRecoveryState()))
            XCTAssertEqual(fixture.defaults.object(forKey: "HaasPendingInput.v1") as? NSObject, value as? NSObject)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        }
    }

    @MainActor
    func testFailedAtomicSaveRetainsCheckpointAndCanRetry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        var state = try store.load()
        state.active = HaasRecoveryRecord(id: UUID(), createdAt: nil)
        state.active?.ledger.append(id: "existing", text: "VoiceInk")
        try store.save(state)
        let original = try Data(contentsOf: fixture.fileURL)
        var candidate = state
        candidate.active?.ledger.append(id: "new", text: " with Haas")

        try fixture.setDirectoryWritable(false)
        XCTAssertThrowsError(try store.save(candidate))
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), original)
        try fixture.setDirectoryWritable(true)
        try store.save(candidate)
        XCTAssertEqual(try fixture.store().load().active?.ledger.fullText, "VoiceInk with Haas")
    }

    @MainActor
    func testFailedMigrationSaveKeepsLegacyUntilDurableRetry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.defaults.set(Self.legacyPayload, forKey: "HaasPendingInput.v1")
        let store = fixture.store()
        let candidate = try store.load()
        try fixture.setDirectoryWritable(false)
        XCTAssertThrowsError(try store.save(candidate))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertEqual(fixture.defaults.data(forKey: "HaasPendingInput.v1"), Self.legacyPayload)
        try fixture.setDirectoryWritable(true)
        try store.save(candidate)
        XCTAssertNil(fixture.defaults.object(forKey: "HaasPendingInput.v1"))
        XCTAssertEqual(try fixture.store().load().archives, candidate.archives)
    }

    @MainActor
    func testExternalFileOrLegacyChangeIsNotSilentlyOverwritten() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let state = try store.load()
        try store.save(state)
        let newerFormat = Data(#"{"version":99,"archives":[]}"#.utf8)
        try newerFormat.write(to: fixture.fileURL)
        XCTAssertThrowsError(try store.save(state))
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), newerFormat)

        let second = try Fixture()
        defer { second.remove() }
        second.defaults.set(Self.legacyPayload, forKey: "HaasPendingInput.v1")
        let secondStore = second.store()
        let migration = try secondStore.load()
        let changedLegacy = Data(#"{"segments":[{"id":"later","text":"later","disposition":"pending"}]}"#.utf8)
        second.defaults.set(changedLegacy, forKey: "HaasPendingInput.v1")
        XCTAssertThrowsError(try secondStore.save(migration))
        XCTAssertEqual(second.defaults.data(forKey: "HaasPendingInput.v1"), changedLegacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.fileURL.path))
    }

    @MainActor
    func testInvalidArchiveOrDuplicateSessionCannotReplaceValidState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        var state = try store.load()
        state.active = HaasRecoveryRecord(id: UUID(), createdAt: nil)
        state.active?.ledger.append(id: "pending", text: "Haas")
        try store.save(state)
        let original = try Data(contentsOf: fixture.fileURL)

        var duplicate = state
        duplicate.archives = [try XCTUnwrap(state.active)]
        XCTAssertThrowsError(try store.save(duplicate))

        var resolvedLedger = HaasSegmentLedger()
        resolvedLedger.append(id: "posted", text: "already entered")
        resolvedLedger.setDisposition(.posted, for: "posted")
        var invalidArchive = state
        invalidArchive.archives = [HaasRecoveryRecord(id: UUID(), createdAt: nil, ledger: resolvedLedger)]
        XCTAssertThrowsError(try store.save(invalidArchive))
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), original)
    }

    private static let legacyPayload = Data(#"{"segments":[{"id":"posted","text":"already entered","disposition":"posted"},{"id":"interrupted","text":"JiHAN Prime","disposition":"posting"},{"id":"pending","text":"Amazon Bedrock","disposition":"pending"},{"id":"copied","text":"already copied","disposition":"copied"}]}"#.utf8)

    private final class LegacyReappearingDefaults: UserDefaults {
        var replacementAfterRemoval: Data?

        override func removeObject(forKey defaultName: String) {
            super.removeObject(forKey: defaultName)
            if defaultName == "HaasPendingInput.v1", let replacementAfterRemoval {
                self.replacementAfterRemoval = nil
                super.set(replacementAfterRemoval, forKey: defaultName)
            }
        }
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let fileURL: URL
        let defaults: UserDefaults
        private let suiteName: String

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fileURL = directory.appendingPathComponent("recovery.json")
            suiteName = "HaasRecoveryStoreTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        }

        func store() -> HaasRecoveryStore {
            HaasRecoveryStore(fileURL: fileURL, legacyDefaults: defaults)
        }

        func setDirectoryWritable(_ writable: Bool) throws {
            try FileManager.default.setAttributes([.posixPermissions: writable ? 0o700 : 0o500], ofItemAtPath: directory.path)
            XCTAssertEqual(FileManager.default.isWritableFile(atPath: directory.path), writable)
        }

        func remove() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
