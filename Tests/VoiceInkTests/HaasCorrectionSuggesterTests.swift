import XCTest
@testable import VoiceInk

final class HaasCorrectionSuggesterTests: XCTestCase {
    private func entry(_ form: String, _ readings: [String]) -> HaasVocabularyEntry {
        HaasVocabularyEntry(id: UUID(), writtenForm: form, readings: readings, category: .person)
    }

    func testSuggestsNewWordWithReadingOfOriginal() {
        let result = HaasCorrectionSuggester.suggestions(
            original: "辰巳さんの資料です", corrected: "巽さんの資料です", entries: []
        )
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .newWord)
        XCTAssertEqual(result.suggestions.first?.before, "辰巳")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "巽")
        XCTAssertEqual(result.suggestions.first?.reading, "たつみ")
    }

    func testIgnoresPunctuationOnlyChange() {
        let result = HaasCorrectionSuggester.suggestions(original: "確認します", corrected: "確認します。", entries: [])
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    func testIgnoresInsertionAndDeletion() {
        let result = HaasCorrectionSuggester.suggestions(original: "資料です", corrected: "新しい資料です", entries: [])
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    func testIgnoresLongRewrite() {
        let long = String(repeating: "あ", count: 21)
        let result = HaasCorrectionSuggester.suggestions(original: "資料です", corrected: "\(long)です", entries: [])
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    func testAddsReadingToExistingWord() {
        let existing = entry("巽", ["そん"])
        let result = HaasCorrectionSuggester.suggestions(original: "辰巳さん", corrected: "巽さん", entries: [existing])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .addReading(entryID: existing.id))
        XCTAssertEqual(result.suggestions.first?.reading, "たつみ")
    }

    func testSkipsWhenWordAlreadyHasReading() {
        let result = HaasCorrectionSuggester.suggestions(
            original: "辰巳さん", corrected: "巽さん", entries: [entry("巽", ["たつみ"])]
        )
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    func testUsesReplacementWhenReadingBelongsToAnotherWord() {
        let result = HaasCorrectionSuggester.suggestions(
            original: "辰巳さん", corrected: "巽さん", entries: [entry("竜巳", ["たつみ"])]
        )
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .replacement)
        XCTAssertEqual(result.suggestions.first?.before, "辰巳")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "巽")
    }

    func testUsesReplacementForShortReading() {
        let result = HaasCorrectionSuggester.suggestions(original: "火です", corrected: "日です", entries: [])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .replacement)
        XCTAssertEqual(result.suggestions.first?.before, "火")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "日")
    }

    func testUsesReplacementWhenReadingUnavailable() {
        let text = "髙さんの資料"
        let tokens = HaasJapaneseReading.tokens(in: text)
        let unreadable = tokens.contains { !$0.hasReading }
        XCTAssertTrue(unreadable, "テスト前提: 読みを返さない語が必要 \(tokens)")
        let result = HaasCorrectionSuggester.suggestions(original: text, corrected: "高さんの資料", entries: [])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .replacement)
    }

    func testUsesReplacementForNonJapaneseBefore() {
        let result = HaasCorrectionSuggester.suggestions(original: "jihanの資料", corrected: "JiHANの資料", entries: [])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .replacement)
        XCTAssertEqual(result.suggestions.first?.before, "jihan")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "JiHAN")
    }

    func testSkipsChangeContainingComma() {
        let result = HaasCorrectionSuggester.suggestions(original: "foo,barの資料", corrected: "bazの資料", entries: [])
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    func testSkipsChangesInsideDictionaryForm() {
        let result = HaasCorrectionSuggester.suggestions(
            original: "辰巳商事の資料", corrected: "巽商事の資料",
            entries: [entry("辰巳商事", ["たつみしょうじ"])]
        )
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.usedDictionaryForms, ["辰巳商事"])
    }
}
