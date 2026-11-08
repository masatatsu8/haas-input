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
        XCTAssertEqual(matcher.apply(to: "自販の件"), "JiHANの件")
        XCTAssertEqual(matcher.apply(to: "自販の件", protecting: ["自販"]), "自販の件")
        XCTAssertEqual(matcher.apply(to: "自販機の件"), "自販機の件")
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

    func testLongerEntryContainingAnotherWrittenFormStillMatches() {
        // 認識が登録済みの「巽」を書いても、それを丸ごと含み、正式表記にも「巽」を残す長い語には置き換える
        let matcher = HaasVocabularyMatcher(entries: [entry("巽", ["たつみ"]), entry("巽雅洋", ["たつみまさひろ"])])
        XCTAssertEqual(matcher.apply(to: "私の名前は巽雅弘です。"), "私の名前は巽雅洋です。")
        XCTAssertEqual(matcher.apply(to: "私の名前は辰巳雅弘です。"), "私の名前は巽雅洋です。")
        XCTAssertEqual(matcher.apply(to: "私の名前は巽雅洋です。"), "私の名前は巽雅洋です。")
        // 正式表記に「巽」を残さない語には置き換えない
        let other = HaasVocabularyMatcher(entries: [entry("巽", ["たつみ"]), entry("立見雅洋", ["たつみまさひろ"])])
        XCTAssertEqual(other.apply(to: "巽雅弘さん"), "巽雅弘さん")
        // 登録済みの語が範囲からはみ出す (一部だけ重なる) 場合も置き換えない
        let partial = HaasVocabularyMatcher(entries: [entry("雅弘さん", []), entry("巽雅洋", ["たつみまさひろ"])])
        XCTAssertEqual(partial.apply(to: "巽雅弘さん"), "巽雅弘さん")
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
        let eight = HaasVocabularyMatcher(entries: [entry("X", ["カキクケコサシス"])])
        XCTAssertEqual(eight.apply(to: "カ・キ・ク・ケ・コ・サ・シ・ス"), "X")
        let nine = HaasVocabularyMatcher(entries: [entry("X", ["カキクケコサシスセ"])])
        XCTAssertEqual(nine.apply(to: "カ・キ・ク・ケ・コ・サ・シ・ス・セ"), "カ・キ・ク・ケ・コ・サ・シ・ス・セ")
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

    func testOrdinaryJapaneseStaysUnchanged() {
        let matcher = HaasVocabularyMatcher(entries: [
            entry("Haas", ["ハース"], .product), entry("巽", ["たつみ"], .person),
            entry("JiHAN Prime", ["ジハンプライム"], .product), entry("JiHAN", ["じはん"]),
        ])
        for sentence in ["会議は明日です", "私は明日休みます", "今日は明日の準備をします",
                         "3時半に集合", "何時半ですか", "自販機の前"] {
            XCTAssertEqual(matcher.apply(to: sentence), sentence, sentence)
        }
    }

    func testKanjiNameInsideLongerCompoundIsLeftAlone() {
        // 受け入れる代償: 漢字に挟まれた範囲は、正しい誤認識でも置換しない。
        let matcher = HaasVocabularyMatcher(entries: [entry("巽", ["たつみ"], .person)])
        XCTAssertEqual(matcher.apply(to: "辰美部長に連絡"), "辰美部長に連絡")
    }

    func testKanjiWithoutReadingNeverJoinsASpan() {
        let matcher = HaasVocabularyMatcher(entries: [entry("Haas", ["ハース"], .product)])
        XCTAssertEqual(matcher.apply(to: "髙 ハース"), "髙 Haas")
        XCTAssertEqual(matcher.apply(to: "ハース 髙"), "Haas 髙")
    }

    func testRejectsOnlyParticleEdgedSpans() {
        let matcher = HaasVocabularyMatcher(entries: [entry("新宿", ["しんじゅく"])])
        XCTAssertEqual(matcher.apply(to: "しんじゅくのオフィス"), "新宿のオフィス")
    }

    func testFallsBackToShorterCandidateWhenLongestIsRejected() {
        let matcher = HaasVocabularyMatcher(entries: [entry("巽", ["たつみ"], .person), entry("Tatsumito", ["たつみと"])])
        XCTAssertEqual(matcher.apply(to: "辰美と話す"), "巽と話す")
    }
}
