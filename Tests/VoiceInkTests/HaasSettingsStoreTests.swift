import XCTest
@testable import VoiceInk

@MainActor
final class HaasSettingsStoreTests: XCTestCase {
    func testSavedNamesReadingsCategoriesAndRuntimePathsSurviveReload() async throws {
        let suite = "HaasSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HaasSettingsStore(defaults: defaults)

        try store.saveEntry(writtenForm: "  JiHAN Prime  ", readings: ["ジハンプライム", "自販プライム"], category: .company)
        try store.saveEntry(writtenForm: "S3 Express One Zone", readings: ["エススリー", " エススリー ", ""], category: .product)
        try store.saveEntry(writtenForm: "Foo, Inc.", readings: [], category: .company)
        store.executablePath = "/Applications/VoiceInk Haas.app/Contents/Resources/Haas/speech"
        store.modelPath = "/Models/Haas Q8.gguf"
        store.vadModelPath = "/Models/silero-vad.gguf"

        let reloaded = HaasSettingsStore(defaults: defaults)
        XCTAssertEqual(try reloaded.vocabularySnapshot(), "JiHAN Prime=ジハンプライム,自販プライム\nS3 Express One Zone=エススリー\nFoo, Inc.")
        XCTAssertEqual(reloaded.entries.map(\.category), [.company, .product, .company])
        XCTAssertEqual(reloaded.executablePath, store.executablePath)
        XCTAssertEqual(reloaded.modelPath, store.modelPath)
        XCTAssertEqual(reloaded.vadModelPath, store.vadModelPath)

        let first = try XCTUnwrap(reloaded.entries.first)
        try reloaded.saveEntry(id: first.id, writtenForm: "JiHAN Prime", readings: ["ジハン プライム"], category: .product)
        try reloaded.removeEntry(id: try XCTUnwrap(reloaded.entries.last).id)
        let edited = HaasSettingsStore(defaults: defaults)
        XCTAssertEqual(try edited.vocabularySnapshot(), "JiHAN Prime=ジハン プライム\nS3 Express One Zone=エススリー")
        XCTAssertEqual(edited.entries.first?.id, first.id)
        XCTAssertEqual(edited.entries.first?.category, .product)
    }

    func testVocabularyEntriesSnapshotReturnsSavedEntriesAndThrowsWhenUnreadable() async throws {
        let suite = "HaasSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HaasSettingsStore(defaults: defaults)
        try store.saveEntry(writtenForm: "VoiceInk", readings: ["ボイスインク"], category: .product)

        let snapshot = try HaasSettingsStore(defaults: defaults).vocabularyEntriesSnapshot()
        XCTAssertEqual(snapshot.map(\.writtenForm), ["VoiceInk"])
        XCTAssertEqual(snapshot.map(\.id), store.entries.map(\.id))

        defaults.set("wrong stored type", forKey: "HaasVocabularyEntriesV1")
        XCTAssertThrowsError(try HaasSettingsStore(defaults: defaults).vocabularyEntriesSnapshot())
    }

    func testInvalidVocabularyCannotChangeSavedDictionary() async throws {
        let suite = "HaasSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HaasSettingsStore(defaults: defaults)
        try store.saveEntry(writtenForm: "VoiceInk", readings: ["ボイスインク"], category: .product)

        let invalid: [(String, [String])] = [
            ("", []),
            ("Bad\nInjected=インジェクト", []),
            ("Bad=Value", []),
            ("Other", ["読み\n別の語"]),
            ("Other", ["読み,別の語"]),
            ("Other", ["読み=別の語"]),
            ("voice ink", ["ボイスインク"]),
            ("ＶｏｉｃｅＩｎｋ", [])
        ]
        for (name, readings) in invalid {
            XCTAssertThrowsError(try store.saveEntry(writtenForm: name, readings: readings, category: .product), name)
        }

        XCTAssertEqual(try HaasSettingsStore(defaults: defaults).vocabularySnapshot(), "VoiceInk=ボイスインク")
    }

    func testUnreadableSavedDictionaryIsPreservedAndBlocksSnapshotAndEdits() async throws {
        let suite = "HaasSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = try HaasVocabularyArchive.encode([])
        let preview = try HaasSettingsStore(defaults: defaults).previewImport(archive)
        let unknownCategory = Data("""
            [{"id":"00000000-0000-0000-0000-000000000001","writtenForm":"Example","readings":[],"category":"unknown"}]
            """.utf8)
        let unreadable: [NSObject] = [
            Data("not a dictionary".utf8) as NSData,
            "wrong stored type" as NSString,
            unknownCategory as NSData,
        ]

        for original in unreadable {
            defaults.set(original, forKey: "HaasVocabularyEntriesV1")
            let store = HaasSettingsStore(defaults: defaults)

            XCTAssertNotNil(store.loadError)
            XCTAssertThrowsError(try store.vocabularySnapshot())
            XCTAssertThrowsError(try store.saveEntry(writtenForm: "VoiceInk", readings: [], category: .product))
            XCTAssertThrowsError(try store.removeEntry(id: UUID()))
            XCTAssertThrowsError(try store.exportVocabulary())
            XCTAssertThrowsError(try store.previewImport(archive))
            XCTAssertThrowsError(try store.applyImport(preview))
            XCTAssertEqual(defaults.object(forKey: "HaasVocabularyEntriesV1") as? NSObject, original)
        }
    }

    func testSharedArchiveTransfersVocabularyWithoutLocalIdentityOrRuntimeSettings() async throws {
        let sourceSuite = "HaasSharingSource.\(UUID().uuidString)"
        let targetSuite = "HaasSharingTarget.\(UUID().uuidString)"
        let sourceDefaults = try XCTUnwrap(UserDefaults(suiteName: sourceSuite))
        let targetDefaults = try XCTUnwrap(UserDefaults(suiteName: targetSuite))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            targetDefaults.removePersistentDomain(forName: targetSuite)
        }
        let source = HaasSettingsStore(defaults: sourceDefaults)
        try source.saveEntry(writtenForm: "VoiceInk", readings: ["ボイスインク"], category: .product)
        for (name, reading, rawCategory) in [
            ("Example Organization", "サンプルソシキ", "company"),
            ("Example Person", "サンプルタロウ", "person"),
            ("Example Term", "サンプルヨウゴ", "other"),
        ] {
            let category = try JSONDecoder().decode(HaasVocabularyCategory.self, from: Data("\"\(rawCategory)\"".utf8))
            try source.saveEntry(writtenForm: name, readings: [reading], category: category)
        }
        source.executablePath = "/private/source/speech"
        source.modelPath = "/private/source/Haas.gguf"
        let originalID = try XCTUnwrap(source.entries.first?.id)
        let data = try source.exportVocabulary()

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["format", "schemaVersion", "entries"])
        XCTAssertEqual(json["format"] as? String, "voiceink.haas-vocabulary")
        XCTAssertEqual(json["schemaVersion"] as? Int, 2)
        let exported = try XCTUnwrap(json["entries"] as? [[String: Any]])
        for entry in exported {
            XCTAssertEqual(Set(entry.keys), ["writtenForm", "readings", "category"])
        }
        XCTAssertEqual(exported.compactMap { $0["category"] as? String }, ["product", "company", "person", "other"])

        let target = HaasSettingsStore(defaults: targetDefaults)
        target.modelPath = "/private/target/Haas.gguf"
        let preview = try target.previewImport(data)
        XCTAssertTrue(target.entries.isEmpty)
        XCTAssertEqual(preview.addedCount, 4)
        let result = try target.applyImport(preview)
        XCTAssertEqual(result.added, 4)
        let reloaded = HaasSettingsStore(defaults: targetDefaults)
        XCTAssertEqual(try reloaded.vocabularySnapshot(), "VoiceInk=ボイスインク\nExample Organization=サンプルソシキ\nExample Person=サンプルタロウ\nExample Term=サンプルヨウゴ")
        XCTAssertEqual(reloaded.entries.map { $0.category.rawValue }, ["product", "company", "person", "other"])
        XCTAssertNotEqual(reloaded.entries.first?.id, originalID)
        XCTAssertEqual(reloaded.modelPath, "/private/target/Haas.gguf")
        XCTAssertTrue(reloaded.executablePath.isEmpty)
    }

    func testImportKeepsConflictsUnlessSelectedAndRejectsStalePreview() async throws {
        let suite = "HaasSharingConflicts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HaasSettingsStore(defaults: defaults)
        try store.saveEntry(writtenForm: "VoiceInk", readings: ["ボイスインク"], category: .product)
        let originalID = try XCTUnwrap(store.entries.first?.id)
        let data = Data("""
            {"format":"voiceink.haas-vocabulary","schemaVersion":1,"entries":[
              {"writtenForm":"VOICE INK","readings":["ヴォイスインク"],"category":"service"},
              {"writtenForm":"Haas","readings":["ハース"],"category":"product"}
            ]}
            """.utf8)
        let preview = try store.previewImport(data)
        XCTAssertEqual(preview.conflictCount, 1)
        XCTAssertEqual(preview.addedCount, 1)
        XCTAssertEqual(try store.vocabularySnapshot(), "VoiceInk=ボイスインク")
        let result = try store.applyImport(preview)
        XCTAssertEqual(result.kept, 1)
        XCTAssertEqual(result.updated, 0)
        XCTAssertEqual(try store.vocabularySnapshot(), "VoiceInk=ボイスインク\nHaas=ハース")

        let updatePreview = try store.previewImport(data)
        let conflict = try XCTUnwrap(updatePreview.items.first { $0.status == .conflict })
        let updated = try store.applyImport(updatePreview, replacing: [conflict.id])
        XCTAssertEqual(updated.updated, 1)
        XCTAssertEqual(store.entries.first?.id, originalID)
        XCTAssertEqual(try HaasSettingsStore(defaults: defaults).vocabularySnapshot(), "VOICE INK=ヴォイスインク\nHaas=ハース")

        let stale = try store.previewImport(data)
        try store.saveEntry(writtenForm: "Amazon Bedrock", readings: ["アマゾンベッドロック"], category: .product)
        let before = try store.vocabularySnapshot()
        XCTAssertThrowsError(try store.applyImport(stale))
        XCTAssertEqual(try HaasSettingsStore(defaults: defaults).vocabularySnapshot(), before)
    }

    func testInvalidSharedFilesAreRejectedBeforeChangingDictionary() async throws {
        let suite = "HaasSharingInvalid.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HaasSettingsStore(defaults: defaults)
        try store.saveEntry(writtenForm: "VoiceInk", readings: [], category: .product)
        let invalidFiles = [
            "not json",
            "{\"format\":\"voiceink.dictionary\",\"schemaVersion\":1,\"entries\":[]}",
            "{\"format\":\"voiceink.haas-vocabulary\",\"schemaVersion\":3,\"entries\":[]}",
            "{\"format\":\"voiceink.haas-vocabulary\",\"schemaVersion\":1,\"entries\":[{\"writtenForm\":\"Bad=Value\",\"readings\":[],\"category\":\"product\"}]}",
            "{\"format\":\"voiceink.haas-vocabulary\",\"schemaVersion\":1,\"entries\":[{\"writtenForm\":\"Haas\",\"readings\":[],\"category\":\"unknown\"}]}",
            "{\"format\":\"voiceink.haas-vocabulary\",\"schemaVersion\":1,\"entries\":[{\"writtenForm\":\"Example Person\",\"readings\":[],\"category\":\"person\"}]}",
            "{\"format\":\"voiceink.haas-vocabulary\",\"schemaVersion\":1,\"entries\":[{\"writtenForm\":\"Example Term\",\"readings\":[],\"category\":\"other\"}]}",
            "{\"format\":\"voiceink.haas-vocabulary\",\"schemaVersion\":2,\"entries\":[{\"writtenForm\":\"Example Service\",\"readings\":[],\"category\":\"service\"}]}",
            "{\"format\":\"voiceink.haas-vocabulary\",\"schemaVersion\":2,\"entries\":[{\"writtenForm\":\"Example\",\"readings\":[],\"category\":\"unknown\"}]}",
            "{\"format\":\"voiceink.haas-vocabulary\",\"schemaVersion\":1,\"entries\":[{\"writtenForm\":\"Haas\",\"readings\":[],\"category\":\"product\"},{\"writtenForm\":\"HAAS\",\"readings\":[],\"category\":\"product\"}]}"
        ]
        for file in invalidFiles {
            XCTAssertThrowsError(try store.previewImport(Data(file.utf8)))
        }
        XCTAssertThrowsError(try store.previewImport(Data(repeating: 0x20, count: 1_048_577)))
        let future = Data("""
            {"format":"voiceink.haas-vocabulary","schemaVersion":3,"entries":[{"category":"future"}]}
            """.utf8)
        XCTAssertThrowsError(try store.previewImport(future)) { error in
            guard case HaasVocabularyArchiveError.unsupportedVersion(3) = error else {
                return XCTFail("An unknown version must be rejected before decoding its entries: \(error)")
            }
        }
        XCTAssertEqual(try HaasSettingsStore(defaults: defaults).vocabularySnapshot(), "VoiceInk")
    }

    func testLegacyLocalCategoriesKeepIdentityWordsAndBytesUntilExplicitSave() async throws {
        let suite = "HaasLegacyCategories.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("""
            [
              {"id":"00000000-0000-0000-0000-000000000001","writtenForm":"Example Organization","readings":["ソシキ","そしき"],"category":"company"},
              {"id":"00000000-0000-0000-0000-000000000002","writtenForm":"Example Product 2","readings":["セイヒン"],"category":"product"},
              {"id":"00000000-0000-0000-0000-000000000003","writtenForm":"Example Service","readings":["サービス","サーヴィス"],"category":"service"}
            ]
            """.utf8)
        defaults.set(original, forKey: "HaasVocabularyEntriesV1")
        let store = HaasSettingsStore(defaults: defaults)
        let expectedWords = "Example Organization=ソシキ,そしき\nExample Product 2=セイヒン\nExample Service=サービス,サーヴィス"

        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.entries.map { $0.category.rawValue }, ["company", "product", "product"])
        XCTAssertEqual(store.entries.map { $0.id.uuidString }, [
            "00000000-0000-0000-0000-000000000001",
            "00000000-0000-0000-0000-000000000002",
            "00000000-0000-0000-0000-000000000003",
        ])
        XCTAssertEqual(try store.vocabularySnapshot(), expectedWords)
        XCTAssertEqual(defaults.data(forKey: "HaasVocabularyEntriesV1"), original)

        let entry = try XCTUnwrap(store.entries.last)
        try store.saveEntry(id: entry.id, writtenForm: entry.writtenForm, readings: entry.readings, category: entry.category)
        let saved = try XCTUnwrap(defaults.data(forKey: "HaasVocabularyEntriesV1"))
        let savedEntries = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        XCTAssertEqual(savedEntries.compactMap { $0["category"] as? String }, ["company", "product", "product"])
        XCTAssertEqual(try HaasSettingsStore(defaults: defaults).vocabularySnapshot(), expectedWords)
        XCTAssertEqual(store.entries.last?.id, entry.id)
    }

    func testVersionOneSharingImportsAllLegacyCategoriesWithoutChangingWords() async throws {
        let suite = "HaasVersionOneSharing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HaasSettingsStore(defaults: defaults)
        let legacy = Data("""
            {"format":"voiceink.haas-vocabulary","schemaVersion":1,"entries":[
              {"writtenForm":"Example Organization","readings":["ソシキ"],"category":"company"},
              {"writtenForm":"Example Product 2","readings":["セイヒン"],"category":"product"},
              {"writtenForm":"Example Service","readings":["サービス","サーヴィス"],"category":"service"}
            ]}
            """.utf8)
        let preview = try store.previewImport(legacy)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(preview.addedCount, 3)
        _ = try store.applyImport(preview)

        XCTAssertEqual(store.entries.map { $0.category.rawValue }, ["company", "product", "product"])
        XCTAssertEqual(try store.vocabularySnapshot(), "Example Organization=ソシキ\nExample Product 2=セイヒン\nExample Service=サービス,サーヴィス")
        let repeated = try store.previewImport(legacy)
        XCTAssertEqual(repeated.unchangedCount, 3)
        XCTAssertEqual(repeated.conflictCount, 0)
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportVocabulary()) as? [String: Any])
        XCTAssertEqual(exported["schemaVersion"] as? Int, 2)
    }
}
