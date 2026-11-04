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
        XCTAssertEqual(matcher.apply(to: "自販機の件"), "JiHAN機の件")
        XCTAssertEqual(matcher.apply(to: "自販機の件", protecting: ["自販"]), "自販機の件")
        XCTAssertEqual(matcher.apply(to: "次半の件"), "JiHANの件")
    }

    func testKanjiAliasReadingsAreConvertedToKana() {
        let matcher = HaasVocabularyMatcher(entries: [entry("JiHAN Prime", ["自販プライム"])])
        XCTAssertEqual(matcher.apply(to: "次半プライムの件"), "JiHAN Primeの件")
    }

    func testDoesNotRewriteOtherEntriesWrittenForms() {
        let matcher = HaasVocabularyMatcher(entries: [entry("次半", []), entry("JiHAN", ["じはん"])])
        XCTAssertEqual(matcher.apply(to: "次半"), "次半")
        XCTAssertEqual(matcher.apply(to: "自販"), "JiHAN")
    }

    func testGapRuleJoinsOnSpaceAndMiddleDotButBreaksOnPunctuation() {
        let matcher = HaasVocabularyMatcher(entries: [entry("X", ["じはんぷらいむ"])])
        XCTAssertEqual(matcher.apply(to: "次半プライム"), "X")
        XCTAssertEqual(matcher.apply(to: "次半・プライム"), "X")
        XCTAssertEqual(matcher.apply(to: "次半 プライム"), "X")
        XCTAssertEqual(matcher.apply(to: "次半、プライム"), "次半、プライム")
    }

    func testLongestMatchBeatsShorterMatch() {
        let matcher = HaasVocabularyMatcher(entries: [entry("A", ["じはん"]), entry("B", ["じはんぷらいむ"])])
        XCTAssertEqual(matcher.apply(to: "次半プライムの件"), "Bの件")
        XCTAssertEqual(matcher.apply(to: "次半の件"), "Aの件")
    }

    func testSpanIsCappedAtEightTokens() {
        let eight = HaasVocabularyMatcher(entries: [entry("X", ["かきくけこさしす"])])
        XCTAssertEqual(eight.apply(to: "か・き・く・け・こ・さ・し・す"), "X")
        let nine = HaasVocabularyMatcher(entries: [entry("X", ["かきくけこさしすせ"])])
        XCTAssertEqual(nine.apply(to: "か・き・く・け・こ・さ・し・す・せ"), "か・き・く・け・こ・さ・し・す・せ")
    }

    func testKeyLengthBoundaryAcceptsThreeAndRejectsTwo() {
        XCTAssertEqual(HaasVocabularyMatcher(entries: [entry("X", ["じはん"])]).apply(to: "次半"), "X")
        XCTAssertEqual(HaasVocabularyMatcher(entries: [entry("X", ["じは"])]).apply(to: "字は"), "字は")
    }

    func testSurroundingSpacesAndPunctuationArePreserved() {
        let matcher = HaasVocabularyMatcher(entries: [entry("巽", ["たつみ"])])
        XCTAssertEqual(matcher.apply(to: " 「辰美さん」 、 確認 "), " 「巽さん」 、 確認 ")
    }

    func testWrittenFormsAreTrimmedAndDeduplicated() {
        let matcher = HaasVocabularyMatcher(entries: [entry(" Haas ", []), entry("Haas", []), entry("  ", []), entry("巽", [])])
        XCTAssertEqual(matcher.writtenForms, ["Haas", "巽"])
    }

    func testEmptyMatcherReturnsInputUnchanged() {
        XCTAssertEqual(HaasVocabularyMatcher.empty.apply(to: "辰美さん"), "辰美さん")
    }
}
