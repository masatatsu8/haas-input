import XCTest
@testable import VoiceInk

final class HaasSessionTranscriptTests: XCTestCase {
    func testCommittedReplacementRunsOnceAndEachSessionKeepsItsOwnText() throws {
        let plan = try WordReplacementPlan(records: [
            .init(id: UUID(), originalText: "自販", replacementText: "JiHAN", dateAdded: Date()),
            .init(id: UUID(), originalText: "JiHAN", replacementText: "二度目の置換", dateAdded: Date()),
        ])
        var first = HaasSessionTranscript(replacements: plan)
        XCTAssertEqual(first.commit(id: "item-1", rawText: "自販の資料"), "JiHANの資料")
        XCTAssertNil(first.commit(id: "item-1", rawText: "自販の資料"))
        XCTAssertEqual(first.preview(rawText: "自販の資料と自販機"), "JiHANの資料と自販機")
        XCTAssertEqual(first.text, "JiHANの資料")

        var next = HaasSessionTranscript(replacements: plan)
        XCTAssertEqual(next.commit(id: "item-1", rawText: "新しい自販の話"), "新しいJiHANの話")
        XCTAssertEqual(next.text, "新しいJiHANの話")
        XCTAssertEqual(first.text, "JiHANの資料")
    }
}
