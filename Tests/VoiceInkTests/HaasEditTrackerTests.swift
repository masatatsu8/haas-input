import XCTest
@testable import VoiceInk

final class HaasEditTrackerTests: XCTestCase {
    private let original = "私の名前は斎藤ひろしです。"

    func testOverwritingSelectionGivesOneHunk() {
        var tracker = HaasEditTracker(original: original)
        tracker.apply(range: NSRange(location: 5, length: 5), replacement: "斎藤博")
        XCTAssertEqual(
            tracker.hunks(in: "私の名前は斎藤博です。"),
            [HaasEditHunk(originalRange: 5..<10, currentRange: 5..<8)])
    }

    func testBackspacingOneByOneThenTyping() {
        var tracker = HaasEditTracker(original: original)
        for location in stride(from: 9, through: 5, by: -1) {
            tracker.apply(range: NSRange(location: location, length: 1), replacement: "")
        }
        // 消しただけで、まだ何も入れていない
        XCTAssertEqual(tracker.hunks(in: "私の名前はです。"), [])
        tracker.apply(range: NSRange(location: 5, length: 0), replacement: "斎藤")
        tracker.apply(range: NSRange(location: 7, length: 0), replacement: "博")
        XCTAssertEqual(
            tracker.hunks(in: "私の名前は斎藤博です。"),
            [HaasEditHunk(originalRange: 5..<10, currentRange: 5..<8)])
    }

    func testInsertionWithoutDeletionGivesNoHunk() {
        var tracker = HaasEditTracker(original: "資料です")
        tracker.apply(range: NSRange(location: 2, length: 0), replacement: "の写し")
        XCTAssertTrue(tracker.isValid)
        XCTAssertEqual(tracker.hunks(in: "資料の写しです"), [])
    }

    func testSeparateEditsGiveSeparateHunks() {
        var tracker = HaasEditTracker(original: "サイトウさんの資料です")
        tracker.apply(range: NSRange(location: 0, length: 4), replacement: "斎藤")
        tracker.apply(range: NSRange(location: 5, length: 2), replacement: "書類")
        XCTAssertEqual(
            tracker.hunks(in: "斎藤さんの書類です"),
            [
                HaasEditHunk(originalRange: 0..<4, currentRange: 0..<2),
                HaasEditHunk(originalRange: 7..<9, currentRange: 5..<7),
            ])
    }

    func testRepeatedMarkedTextReplacementOnSelection() {
        // 選んだ「斎藤ひろし」の上で日本語入力を始め、変換中の文字を何度も置き換えてから確定する
        var tracker = HaasEditTracker(original: original)
        tracker.apply(range: NSRange(location: 5, length: 5), replacement: "ｓ")
        tracker.apply(range: NSRange(location: 5, length: 1), replacement: "さ")
        tracker.apply(range: NSRange(location: 5, length: 1), replacement: "さい")
        tracker.apply(range: NSRange(location: 5, length: 2), replacement: "さいｔ")
        tracker.apply(range: NSRange(location: 5, length: 3), replacement: "さいと")
        tracker.apply(range: NSRange(location: 5, length: 3), replacement: "さいとうひろし")
        tracker.apply(range: NSRange(location: 5, length: 7), replacement: "斎藤博")
        tracker.apply(range: NSRange(location: 5, length: 3), replacement: "斎藤博")
        XCTAssertEqual(
            tracker.hunks(in: "私の名前は斎藤博です。"),
            [HaasEditHunk(originalRange: 5..<10, currentRange: 5..<8)])
    }

    func testOutOfRangeEditInvalidates() {
        var tracker = HaasEditTracker(original: original)
        tracker.apply(range: NSRange(location: 12, length: 2), replacement: "x")
        XCTAssertFalse(tracker.isValid)
        tracker.apply(range: NSRange(location: 5, length: 5), replacement: "斎藤博")
        XCTAssertEqual(tracker.hunks(in: "私の名前は斎藤博です。"), [])

        var notFound = HaasEditTracker(original: original)
        notFound.apply(range: NSRange(location: NSNotFound, length: 0), replacement: "x")
        XCTAssertFalse(notFound.isValid)
    }

    func testMismatchedTextInvalidates() {
        var tracker = HaasEditTracker(original: original)
        tracker.apply(range: NSRange(location: 5, length: 5), replacement: "斎藤博")
        // 取りこぼした置き換えがあると、欄の中身は記録と合わない
        XCTAssertEqual(tracker.hunks(in: "私の名前は斉藤博です。"), [])
        tracker.check("私の名前は斉藤博です。")
        XCTAssertFalse(tracker.isValid)
        XCTAssertEqual(tracker.hunks(in: "私の名前は斎藤博です。"), [])
    }

    func testNormalizationDifferenceCountsAsMismatch() {
        // 「が」を1文字 (U+304C) で持つ記録に、「か」+濁点 (U+304B U+3099) の欄は合わない
        let composed = "がっこう"
        let decomposed = "\u{304B}\u{3099}っこう"
        XCTAssertEqual(composed, decomposed, "テスト前提: String の == では等しい")
        var tracker = HaasEditTracker(original: composed)
        tracker.apply(range: NSRange(location: 1, length: 1), replacement: "ッ")
        XCTAssertEqual(tracker.hunks(in: "\u{304B}\u{3099}ッこう"), [])
        tracker.check(decomposed)
        XCTAssertFalse(tracker.isValid)
    }
}
