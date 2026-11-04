import XCTest
@testable import VoiceInk

final class HaasVocabularyMatcherTests: XCTestCase {
    private func entry(_ name: String, _ readings: [String], _ category: HaasVocabularyCategory = .other) -> HaasVocabularyEntry {
        HaasVocabularyEntry(id: UUID(), writtenForm: name, readings: readings, category: category)
    }

    func testReplacesMisrecognizedSpansWhoseReadingMatchesAnEntry() {
        let matcher = HaasVocabularyMatcher(entries: [
            entry("巽", ["たつみ"], .person), entry("JiHAN Prime", ["ジハンプライム"], .product),
            entry("Haas", ["ハース"], .product),
        ])
        XCTAssertEqual(matcher.apply(to: "辰美さんに次半プライムの改正内容を確認します。"),
                       "巽さんにJiHAN Primeの改正内容を確認します。")
        XCTAssertEqual(matcher.apply(to: "明日の会議でハースの精度を報告します。"), "明日の会議でHaasの精度を報告します。")
    }

    func testKeepsTextThatAlreadyUsesTheWrittenForm() {
        let matcher = HaasVocabularyMatcher(entries: [entry("JiHAN Prime", ["ジハンプライム"]), entry("巽", ["たつみ"])])
        XCTAssertEqual(matcher.apply(to: "JiHAN Primeの件で巽さんに連絡します。"), "JiHAN Primeの件で巽さんに連絡します。")
    }

    func testIgnoresShortReadingsAmbiguousKeysAndNonJapaneseTokens() {
        let matcher = HaasVocabularyMatcher(entries: [
            entry("可", ["か"]), entry("SEI", ["せい"]),
            entry("立見", ["たつみ"]), entry("龍美", ["タツミ"]),
            entry("ジハン", ["じはん"]),
        ])
        XCTAssertEqual(matcher.apply(to: "せいかの確認"), "せいかの確認")
        XCTAssertEqual(matcher.apply(to: "辰美さん"), "辰美さん")
        XCTAssertEqual(matcher.apply(to: "JiHAN の件"), "JiHAN の件")
    }

    func testUsesKanaOnlyWrittenFormAsItsOwnReadingAcrossMiddleDots() {
        let matcher = HaasVocabularyMatcher(entries: [entry("サードインテリジェンス", [])])
        XCTAssertEqual(matcher.apply(to: "サード・インテリジェンスの資料"), "サードインテリジェンスの資料")
    }

    func testDoesNotRewriteProtectedTexts() {
        let matcher = HaasVocabularyMatcher(entries: [entry("JiHAN", ["じはん"])])
        XCTAssertEqual(matcher.apply(to: "自販機の件", protecting: ["自販"]), "自販機の件")
        XCTAssertEqual(matcher.apply(to: "次半の件"), "JiHANの件")
    }

    func testKanjiAliasReadingsAreConvertedToKana() {
        let matcher = HaasVocabularyMatcher(entries: [entry("JiHAN Prime", ["自販プライム"])])
        XCTAssertEqual(matcher.apply(to: "次半プライムの件"), "JiHAN Primeの件")
    }

    func testEmptyMatcherReturnsInputUnchanged() {
        XCTAssertEqual(HaasVocabularyMatcher.empty.apply(to: "辰美さん"), "辰美さん")
    }
}
