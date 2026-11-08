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

    func testKanaWrittenFormOfAnotherEntryCountsAsSameReading() {
        // 「タツミ」は読みがなくても、照合ではカナの正式表記を読み「たつみ」として使う
        let result = HaasCorrectionSuggester.suggestions(
            original: "辰巳さんの資料です", corrected: "巽さんの資料です", entries: [entry("タツミ", [])]
        )
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .replacement)
        XCTAssertEqual(result.suggestions.first?.writtenForm, "巽")
    }

    func testNewKanaWrittenFormThatCollidesBecomesReplacement() {
        // 新しい語「タツミ」は、正式表記から読み「たつみ」が増え、「巽」の読みとぶつかる
        let result = HaasCorrectionSuggester.suggestions(
            original: "東京さんの資料です", corrected: "タツミさんの資料です", entries: [entry("巽", ["たつみ"])]
        )
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .replacement)
        XCTAssertEqual(result.suggestions.first?.writtenForm, "タツミ")
    }

    // MARK: - 長い文

    func testLongIdenticalTextHasNoChanges() {
        let long = String(repeating: "資料を確認します。", count: 3_000)
        XCTAssertEqual(HaasCorrectionDiff.changes(from: long, to: long), [])
        XCTAssertTrue(HaasCorrectionSuggester.suggestions(original: long, corrected: long, entries: []).suggestions.isEmpty)
    }

    func testLongTextWithOneSmallChangeStillSuggests() {
        // 前後の共通の語を除くので、全文が長くても違う部分だけを比べる
        let long = String(repeating: "資料を確認します。", count: 1_500)
        let result = HaasCorrectionSuggester.suggestions(
            original: long + "辰巳さんの資料です。" + long, corrected: long + "巽さんの資料です。" + long, entries: []
        )
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .newWord)
        XCTAssertEqual(result.suggestions.first?.before, "辰巳")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "巽")
    }

    func testTooLargeDifferenceGivesNoSuggestions() {
        // 違う部分の語の数の積が上限を超えるときは、表を作らずに候補を出さない
        let original = String(repeating: "りんご、", count: 300)
        let corrected = String(repeating: "みかん、", count: 300)
        let oldCount = HaasJapaneseReading.tokens(in: original).count
        let newCount = HaasJapaneseReading.tokens(in: corrected).count
        XCTAssertGreaterThan(oldCount * newCount, HaasCorrectionDiff.maximumTableCells, "テスト前提")
        XCTAssertEqual(HaasCorrectionDiff.changes(from: original, to: corrected), [])
        XCTAssertTrue(
            HaasCorrectionSuggester.suggestions(original: original, corrected: corrected, entries: []).suggestions.isEmpty)
    }

    func testSkipsChangesInsideDictionaryForm() {
        let result = HaasCorrectionSuggester.suggestions(
            original: "辰巳商事の資料", corrected: "巽商事の資料",
            entries: [entry("辰巳商事", ["たつみしょうじ"])]
        )
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.usedDictionaryForms, ["辰巳商事"])
    }

    // MARK: - 手で直した塊

    private let named = "私の名前は巽まさひろです。"
    private let renamed = "私の名前は巽雅洋です。"
    /// 「巽まさひろ」を消して「巽雅洋」を入れた
    private let renaming = HaasEditHunk(originalRange: 5..<10, currentRange: 5..<8)

    func testWidensChangeToEditedSpan() {
        for entries in [[], [entry("巽", ["たつみ"])]] {
            let result = HaasCorrectionSuggester.suggestions(
                original: named, corrected: renamed, entries: entries, hunks: [renaming])
            XCTAssertEqual(result.suggestions.count, 1, "\(entries.map(\.writtenForm))")
            XCTAssertEqual(result.suggestions.first?.kind, .newWord)
            XCTAssertEqual(result.suggestions.first?.before, "巽まさひろ")
            XCTAssertEqual(result.suggestions.first?.writtenForm, "巽雅洋")
            XCTAssertEqual(result.suggestions.first?.reading, "たつみまさひろ")
            XCTAssertEqual(result.usedDictionaryForms, [])
        }
    }

    func testWithoutHunksSuggestsOnlyChangedWord() {
        let result = HaasCorrectionSuggester.suggestions(original: named, corrected: renamed, entries: [])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .newWord)
        XCTAssertEqual(result.suggestions.first?.before, "まさひろ")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "雅洋")
        XCTAssertEqual(result.suggestions.first?.reading, "まさひろ")
    }

    func testOverDeletedFunctionWordsAreNotIncluded() {
        // 文末から「まさひろです。」まで消して「雅洋です。」と打った。「です」で止まる
        let tail = HaasCorrectionSuggester.suggestions(
            original: named, corrected: renamed, entries: [],
            hunks: [HaasEditHunk(originalRange: 6..<13, currentRange: 6..<11)])
        XCTAssertEqual(tail.suggestions.map(\.before), ["まさひろ"])
        XCTAssertEqual(tail.suggestions.map(\.writtenForm), ["雅洋"])

        // 「は巽まさひろ」まで消して「は巽雅洋」と打った。「巽」は含め、「は」で止まる
        let head = HaasCorrectionSuggester.suggestions(
            original: named, corrected: renamed, entries: [],
            hunks: [HaasEditHunk(originalRange: 4..<10, currentRange: 4..<8)])
        XCTAssertEqual(head.suggestions.map(\.before), ["巽まさひろ"])
        XCTAssertEqual(head.suggestions.map(\.writtenForm), ["巽雅洋"])
    }

    func testRetypedWholeSentenceWidensOnlyToName() {
        // 文全体を打ち直した。左は「巽」を含めて「は」で、右は「です」で止まる
        let result = HaasCorrectionSuggester.suggestions(
            original: named, corrected: renamed, entries: [entry("巽", ["たつみ"])],
            hunks: [HaasEditHunk(originalRange: 0..<named.utf16.count, currentRange: 0..<renamed.utf16.count)])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .newWord)
        XCTAssertEqual(result.suggestions.first?.before, "巽まさひろ")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "巽雅洋")
        XCTAssertEqual(result.suggestions.first?.reading, "たつみまさひろ")
    }

    func testTooLongWidenedChangeFallsBackToWordChange() {
        // 漢字・カタカナの語が続くので文の頭まで広がり、20文字を超える
        let organization = "国立研究開発法人新エネルギー産業技術総合開発機構"
        let original = organization + "巽まさひろです。"
        let corrected = organization + "巽雅洋です。"
        let whole = HaasEditHunk(originalRange: 0..<original.utf16.count, currentRange: 0..<corrected.utf16.count)
        XCTAssertGreaterThan((organization + "巽雅洋").count, HaasCorrectionSuggester.maximumCorrectedLength, "テスト前提")
        let result = HaasCorrectionSuggester.suggestions(
            original: original, corrected: corrected, entries: [], hunks: [whole])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.before, "まさひろ")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "雅洋")
    }

    func testEditedSpanChangingDictionaryFormIsStillSkipped() {
        // 辞書の「巽」を別の表記に変えた
        let result = HaasCorrectionSuggester.suggestions(
            original: named, corrected: "私の名前は辰巳雅洋です。", entries: [entry("巽", ["たつみ"])],
            hunks: [HaasEditHunk(originalRange: 5..<10, currentRange: 5..<9)])
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.usedDictionaryForms, ["巽"])
    }

    func testChangesWidenedOverSameWordAreMerged() {
        // 「辰巳東京支店」をまとめて打ち直すと、「東京」を挟む語の差分の2か所が1つになる
        let result = HaasCorrectionSuggester.suggestions(
            original: "辰巳東京支店", corrected: "巽東京支社", entries: [],
            hunks: [HaasEditHunk(originalRange: 0..<6, currentRange: 0..<5)])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.before, "辰巳東京支店")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "巽東京支社")
        XCTAssertEqual(result.suggestions.first?.reading, "たつみとうきょうしてん")
    }

    func testFunctionWordsAcrossChangesAreNotMerged() {
        // 「辰巳さんの資料」をまとめて打ち直しても、間の「さん」「の」はひらがななので広げない
        let result = HaasCorrectionSuggester.suggestions(
            original: "辰巳さんの資料です", corrected: "巽さんの書類です", entries: [],
            hunks: [HaasEditHunk(originalRange: 0..<7, currentRange: 0..<6)])
        XCTAssertEqual(result.suggestions.map(\.before), ["辰巳", "資料"])
        XCTAssertEqual(result.suggestions.map(\.writtenForm), ["巽", "書類"])
    }

    func testDoesNotWidenAcrossSeparatorsBetweenWords() {
        // トークナイザーは「。」「・」空白を語にしないので、語の間に残る。そこを越えて広げない
        for separator in ["。", "・", " "] {
            let original = "辰巳\(separator)東京支店"
            let corrected = "巽\(separator)東京支社"
            let result = HaasCorrectionSuggester.suggestions(
                original: original, corrected: corrected, entries: [],
                hunks: [HaasEditHunk(originalRange: 0..<original.utf16.count, currentRange: 0..<corrected.utf16.count)])
            XCTAssertEqual(result.suggestions.map(\.before), ["辰巳", "東京支店"], separator)
            XCTAssertEqual(result.suggestions.map(\.writtenForm), ["巽", "東京支社"], separator)
        }
    }

    func testChangingOneOfRepeatedDictionaryFormsIsStillSkipped() {
        // 塊の中の辞書の「巽」2つのうち1つを「辰巳」に変えた。もう1つが残っていても候補にしない
        let original = "巽東京巽まさひろ"
        let corrected = "辰巳東京巽雅洋"
        let result = HaasCorrectionSuggester.suggestions(
            original: original, corrected: corrected, entries: [entry("巽", ["たつみ"])],
            hunks: [HaasEditHunk(originalRange: 0..<original.utf16.count, currentRange: 0..<corrected.utf16.count)])
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.usedDictionaryForms, ["巽"])
    }

    func testMergedChangeTooLongFallsBackToWordChanges() {
        // 両端の変更はそれぞれ広げると20文字だが、まとめると22文字になる
        let shared = "国立研究開発法人新エネルギー産業技術"
        let original = "東京" + shared + "支店"
        let corrected = "大阪" + shared + "支社"
        XCTAssertEqual(("東京" + shared).count, HaasCorrectionSuggester.maximumCorrectedLength, "テスト前提")
        let result = HaasCorrectionSuggester.suggestions(
            original: original, corrected: corrected, entries: [],
            hunks: [HaasEditHunk(originalRange: 0..<original.utf16.count, currentRange: 0..<corrected.utf16.count)])
        XCTAssertEqual(result.suggestions.map(\.before), ["東京", "支店"])
        XCTAssertEqual(result.suggestions.map(\.writtenForm), ["大阪", "支社"])
    }

    func testWordsThatStopWidening() {
        for surface in ["です", "は", "すごーい", "。", "、", "・", "「", "ー", "　", "ゝ"] {
            XCTAssertTrue(HaasCorrectionDiff.stopsWidening(surface), surface)
        }
        for surface in ["巽", "お願い", "マサヒロ", "ジー", "ABC", "２０２６", "佐々木"] {
            XCTAssertFalse(HaasCorrectionDiff.stopsWidening(surface), surface)
        }
    }

    func testHunkAwayFromChangeLeavesItAsIs() {
        // 「です」を消して打ち直しても、「辰巳 → 巽」は広げない
        let result = HaasCorrectionSuggester.suggestions(
            original: "辰巳さんの資料です", corrected: "巽さんの資料です", entries: [],
            hunks: [HaasEditHunk(originalRange: 7..<9, currentRange: 6..<8)])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.before, "辰巳")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "巽")
    }
}
