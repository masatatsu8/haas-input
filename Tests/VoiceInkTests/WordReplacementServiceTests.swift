import SwiftData
import XCTest
@testable import VoiceInk

@MainActor
final class WordReplacementServiceTests: XCTestCase {
    func testHaasProtectsHanRunsAndAllowsExplicitLongerRules() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(WordReplacement(originalText: "自販", replacementText: "JiHAN"))
        try context.save()

        let short = try WordReplacementService.shared.snapshot(using: context)
        XCTAssertEqual(short.apply(to: "自販の資料。自販です。自販機、株式会社自販、自販事業、𠀀自販、自販𠀀、々自販。"),
                       "JiHANの資料。JiHANです。自販機、株式会社自販、自販事業、𠀀自販、自販𠀀、々自販。")

        context.insert(WordReplacement(originalText: "株式会社自販", replacementText: "Example Company"))
        try context.save()
        let longer = try WordReplacementService.shared.snapshot(using: context)
        XCTAssertEqual(longer.apply(to: "株式会社自販の資料。自販の資料。自販機。株式会社自販機。"),
                       "Example Companyの資料。JiHANの資料。自販機。株式会社自販機。")
    }

    func testVariantsCaseBoundariesAndLiteralReplacementRemainAvailable() throws {
        let container = try makeContainer()
        let context = container.mainContext
        for (source, replacement) in [
            ("Voicing, Voice ink, VOICE INK", "VoiceInk"),
            ("cat", "$5\\path"),
            ("Foo", "Bar"),
            ("Bar", "Baz"),
        ] {
            context.insert(WordReplacement(originalText: source, replacementText: replacement))
        }
        try context.save()
        let plan = try WordReplacementService.shared.snapshot(using: context)
        XCTAssertEqual(plan.apply(to: "VOICING / voice ink。catの cats (CAT)。Foo Bar。"),
                       "VoiceInk / VoiceInk。$5\\pathの cats ($5\\path)。Bar Baz。")
    }

    func testSnapshotsStayFrozenWhileFollowingSessionsSeeSavedEdits() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let replacement = WordReplacement(originalText: "自販", replacementText: "JiHAN")
        context.insert(replacement)
        try context.save()

        let frozen = try WordReplacementService.shared.snapshot(using: context)
        replacement.replacementText = "New Name"
        try context.save()
        let next = try WordReplacementService.shared.snapshot(using: context)
        XCTAssertEqual(frozen.apply(to: "自販の資料"), "JiHANの資料")
        XCTAssertEqual(next.apply(to: "自販の資料"), "New Nameの資料")

        context.delete(replacement)
        try context.save()
        let empty = try WordReplacementService.shared.snapshot(using: context)
        XCTAssertEqual(frozen.apply(to: "自販の資料"), "JiHANの資料")
        XCTAssertEqual(empty.apply(to: "自販の資料"), "自販の資料")
    }

    func testLegacyDuplicateRulesKeepDateThenIDTieBreaks() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let earlier = WordReplacement(originalText: "datekey", replacementText: "Earlier", dateAdded: Date(timeIntervalSince1970: 10))
        let later = WordReplacement(originalText: "datekey", replacementText: "Later", dateAdded: Date(timeIntervalSince1970: 20))
        let lowerID = WordReplacement(originalText: "idkey", replacementText: "First ID", dateAdded: Date(timeIntervalSince1970: 30))
        lowerID.id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let higherID = WordReplacement(originalText: "idkey", replacementText: "Second ID", dateAdded: Date(timeIntervalSince1970: 30))
        higherID.id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        for entry in [higherID, later, lowerID, earlier] { context.insert(entry) }
        try context.save()

        let plan = try WordReplacementService.shared.snapshot(using: context)
        XCTAssertEqual(plan.apply(to: "DATEKEY IDKEY"), "Earlier First ID")
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([WordReplacement.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
