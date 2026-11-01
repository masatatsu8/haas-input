import XCTest
@testable import VoiceInk

final class CleanupDefaultsMigrationTests: XCTestCase {
    func testInitialCleanupDefaultsKeepLegacyBehaviorAndSurviveRestartAfterFreshInstall() throws {
        struct Case {
            let name: String
            let hasStore: Bool
            let stored: [String: Any]
            let expectedEnabled: Bool
            let expectedMinutes: Int
        }
        let cases = [
            Case(name: "既存データで未設定", hasStore: true, stored: [:], expectedEnabled: false, expectedMinutes: 1440),
            Case(name: "新規インストール", hasStore: false, stored: [:], expectedEnabled: true, expectedMinutes: 10080),
            Case(name: "既存データで期間だけ設定済み", hasStore: true,
                 stored: [CleanupSettingsKeys.transcriptionRetentionMinutes: 60], expectedEnabled: false, expectedMinutes: 60),
            Case(name: "既存データで有効を選択済み", hasStore: true,
                 stored: [CleanupSettingsKeys.isTranscriptionCleanupEnabled: true,
                          CleanupSettingsKeys.transcriptionRetentionMinutes: 4320], expectedEnabled: true, expectedMinutes: 4320),
        ]
        for testCase in cases {
            let (defaults, directory) = try makeEnvironment()
            if testCase.hasStore { try createStore(in: directory) }
            for (key, value) in testCase.stored { defaults.set(value, forKey: key) }

            CleanupDefaultsMigration.persistInitialCleanupDefaults(defaults: defaults, storageDirectory: directory)

            XCTAssertEqual(defaults.object(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled) as? Bool,
                           testCase.expectedEnabled, testCase.name)
            XCTAssertEqual(defaults.object(forKey: CleanupSettingsKeys.transcriptionRetentionMinutes) as? Int,
                           testCase.expectedMinutes, testCase.name)
        }

        // 新規インストールの初回起動後にストアが作られても、次回起動で旧版のデータと誤認しない。
        let (defaults, directory) = try makeEnvironment()
        CleanupDefaultsMigration.persistInitialCleanupDefaults(defaults: defaults, storageDirectory: directory)
        try createStore(in: directory)
        CleanupDefaultsMigration.persistInitialCleanupDefaults(defaults: defaults, storageDirectory: directory)
        XCTAssertEqual(defaults.object(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: CleanupSettingsKeys.transcriptionRetentionMinutes) as? Int, 10080)
    }

    private func makeEnvironment() throws -> (UserDefaults, URL) {
        let suite = "CleanupDefaultsMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (defaults, directory)
    }

    private func createStore(in directory: URL) throws {
        try Data().write(to: directory.appendingPathComponent("default.store"))
    }
}
