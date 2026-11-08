import XCTest
@testable import VoiceInk

final class HaasEditTrackerTests: XCTestCase {
    private let original = "私の名前は巽まさひろです。"

    func testOverwritingSelectionGivesOneHunk() {
        var tracker = HaasEditTracker(original: original)
        tracker.apply(range: NSRange(location: 5, length: 5), replacement: "巽雅洋")
        XCTAssertEqual(
            tracker.hunks(in: "私の名前は巽雅洋です。"),
            [HaasEditHunk(originalRange: 5..<10, currentRange: 5..<8)])
    }

    func testBackspacingOneByOneThenTyping() {
        var tracker = HaasEditTracker(original: original)
        for location in stride(from: 9, through: 5, by: -1) {
            tracker.apply(range: NSRange(location: location, length: 1), replacement: "")
        }
        // 消しただけで、まだ何も入れていない
        XCTAssertEqual(tracker.hunks(in: "私の名前はです。"), [])
        tracker.apply(range: NSRange(location: 5, length: 0), replacement: "巽")
        tracker.apply(range: NSRange(location: 6, length: 0), replacement: "雅洋")
        XCTAssertEqual(
            tracker.hunks(in: "私の名前は巽雅洋です。"),
            [HaasEditHunk(originalRange: 5..<10, currentRange: 5..<8)])
    }

    func testInsertionWithoutDeletionGivesNoHunk() {
        var tracker = HaasEditTracker(original: "資料です")
        tracker.apply(range: NSRange(location: 2, length: 0), replacement: "の写し")
        XCTAssertTrue(tracker.isValid)
        XCTAssertEqual(tracker.hunks(in: "資料の写しです"), [])
    }

    func testSeparateEditsGiveSeparateHunks() {
        var tracker = HaasEditTracker(original: "辰巳さんの資料です")
        tracker.apply(range: NSRange(location: 0, length: 2), replacement: "巽")
        tracker.apply(range: NSRange(location: 4, length: 2), replacement: "書類")
        XCTAssertEqual(
            tracker.hunks(in: "巽さんの書類です"),
            [
                HaasEditHunk(originalRange: 0..<2, currentRange: 0..<1),
                HaasEditHunk(originalRange: 5..<7, currentRange: 4..<6),
            ])
    }

    func testRepeatedMarkedTextReplacementOnSelection() {
        // 選んだ「巽まさひろ」の上で日本語入力を始め、変換中の文字を何度も置き換えてから確定する
        var tracker = HaasEditTracker(original: original)
        tracker.apply(range: NSRange(location: 5, length: 5), replacement: "ｔ")
        tracker.apply(range: NSRange(location: 5, length: 1), replacement: "た")
        tracker.apply(range: NSRange(location: 5, length: 1), replacement: "たｔ")
        tracker.apply(range: NSRange(location: 5, length: 2), replacement: "たつ")
        tracker.apply(range: NSRange(location: 5, length: 2), replacement: "たつみまさひろ")
        tracker.apply(range: NSRange(location: 5, length: 7), replacement: "巽雅洋")
        tracker.apply(range: NSRange(location: 5, length: 3), replacement: "巽雅洋")
        XCTAssertEqual(
            tracker.hunks(in: "私の名前は巽雅洋です。"),
            [HaasEditHunk(originalRange: 5..<10, currentRange: 5..<8)])
    }

    func testOutOfRangeEditInvalidates() {
        var tracker = HaasEditTracker(original: original)
        tracker.apply(range: NSRange(location: 12, length: 2), replacement: "x")
        XCTAssertFalse(tracker.isValid)
        tracker.apply(range: NSRange(location: 5, length: 5), replacement: "巽雅洋")
        XCTAssertEqual(tracker.hunks(in: "私の名前は巽雅洋です。"), [])

        var notFound = HaasEditTracker(original: original)
        notFound.apply(range: NSRange(location: NSNotFound, length: 0), replacement: "x")
        XCTAssertFalse(notFound.isValid)
    }

    func testMismatchedTextInvalidates() {
        var tracker = HaasEditTracker(original: original)
        tracker.apply(range: NSRange(location: 5, length: 5), replacement: "巽雅洋")
        // 取りこぼした置き換えがあると、欄の中身は記録と合わない
        XCTAssertEqual(tracker.hunks(in: "私の名前は辰巳雅洋です。"), [])
        tracker.check("私の名前は辰巳雅洋です。")
        XCTAssertFalse(tracker.isValid)
        XCTAssertEqual(tracker.hunks(in: "私の名前は巽雅洋です。"), [])
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
