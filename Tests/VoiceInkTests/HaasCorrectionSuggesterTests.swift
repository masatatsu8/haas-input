import XCTest
@testable import VoiceInk

final class HaasCorrectionSuggesterTests: XCTestCase {
    private func entry(_ form: String, _ readings: [String]) -> HaasVocabularyEntry {
        HaasVocabularyEntry(id: UUID(), writtenForm: form, readings: readings, category: .person)
    }

    func testSuggestsNewWordWithReadingOfOriginal() {
        let result = HaasCorrectionSuggester.suggestions(
            original: "斉藤さんの資料です", corrected: "斎藤さんの資料です", entries: []
        )
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .newWord)
        XCTAssertEqual(result.suggestions.first?.before, "斉藤")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "斎藤")
        XCTAssertEqual(result.suggestions.first?.reading, "さいとう")
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
        let existing = entry("斎藤", ["そん"])
        let result = HaasCorrectionSuggester.suggestions(original: "斉藤さん", corrected: "斎藤さん", entries: [existing])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .addReading(entryID: existing.id))
        XCTAssertEqual(result.suggestions.first?.reading, "さいとう")
    }

    func testSkipsWhenWordAlreadyHasReading() {
        let result = HaasCorrectionSuggester.suggestions(
            original: "斉藤さん", corrected: "斎藤さん", entries: [entry("斎藤", ["さいとう"])]
        )
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    func testUsesReplacementWhenReadingBelongsToAnotherWord() {
        let result = HaasCorrectionSuggester.suggestions(
            original: "斉藤さん", corrected: "斎藤さん", entries: [entry("西藤", ["さいとう"])]
        )
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .replacement)
        XCTAssertEqual(result.suggestions.first?.before, "斉藤")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "斎藤")
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
        // 「サイトウ」は読みがなくても、照合ではカナの正式表記を読み「さいとう」として使う
        let result = HaasCorrectionSuggester.suggestions(
            original: "斉藤さんの資料です", corrected: "斎藤さんの資料です", entries: [entry("サイトウ", [])]
        )
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .replacement)
        XCTAssertEqual(result.suggestions.first?.writtenForm, "斎藤")
    }

    func testNewKanaWrittenFormThatCollidesBecomesReplacement() {
        // 新しい語「サイトウ」は、正式表記から読み「さいとう」が増え、「斎藤」の読みとぶつかる
        let result = HaasCorrectionSuggester.suggestions(
            original: "東京さんの資料です", corrected: "サイトウさんの資料です", entries: [entry("斎藤", ["さいとう"])]
        )
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .replacement)
        XCTAssertEqual(result.suggestions.first?.writtenForm, "サイトウ")
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
            original: long + "斉藤さんの資料です。" + long, corrected: long + "斎藤さんの資料です。" + long, entries: []
        )
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .newWord)
        XCTAssertEqual(result.suggestions.first?.before, "斉藤")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "斎藤")
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
            original: "斉藤商事の資料", corrected: "斎藤商事の資料",
            entries: [entry("斉藤商事", ["さいとうしょうじ"])]
        )
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.usedDictionaryForms, ["斉藤商事"])
    }

    // MARK: - 手で直した塊

    private let named = "私の名前は斎藤ひろしです。"
    private let renamed = "私の名前は斎藤博です。"
    /// 「斎藤ひろし」を消して「斎藤博」を入れた
    private let renaming = HaasEditHunk(originalRange: 5..<10, currentRange: 5..<8)

    func testWidensChangeToEditedSpan() {
        for entries in [[], [entry("斎藤", ["さいとう"])]] {
            let result = HaasCorrectionSuggester.suggestions(
                original: named, corrected: renamed, entries: entries, hunks: [renaming])
            XCTAssertEqual(result.suggestions.count, 1, "\(entries.map(\.writtenForm))")
            XCTAssertEqual(result.suggestions.first?.kind, .newWord)
            XCTAssertEqual(result.suggestions.first?.before, "斎藤ひろし")
            XCTAssertEqual(result.suggestions.first?.writtenForm, "斎藤博")
            XCTAssertEqual(result.suggestions.first?.reading, "さいとうひろし")
            XCTAssertEqual(result.usedDictionaryForms, [])
        }
    }

    func testWithoutHunksSuggestsOnlyChangedWord() {
        let result = HaasCorrectionSuggester.suggestions(original: named, corrected: renamed, entries: [])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .newWord)
        XCTAssertEqual(result.suggestions.first?.before, "ひろし")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "博")
        XCTAssertEqual(result.suggestions.first?.reading, "ひろし")
    }

    func testOverDeletedFunctionWordsAreNotIncluded() {
        // 文末から「ひろしです。」まで消して「博です。」と打った。「です」で止まる
        let tail = HaasCorrectionSuggester.suggestions(
            original: named, corrected: renamed, entries: [],
            hunks: [HaasEditHunk(originalRange: 7..<13, currentRange: 7..<11)])
        XCTAssertEqual(tail.suggestions.map(\.before), ["ひろし"])
        XCTAssertEqual(tail.suggestions.map(\.writtenForm), ["博"])

        // 「は斎藤ひろし」まで消して「は斎藤博」と打った。「斎藤」は含め、「は」で止まる
        let head = HaasCorrectionSuggester.suggestions(
            original: named, corrected: renamed, entries: [],
            hunks: [HaasEditHunk(originalRange: 4..<10, currentRange: 4..<8)])
        XCTAssertEqual(head.suggestions.map(\.before), ["斎藤ひろし"])
        XCTAssertEqual(head.suggestions.map(\.writtenForm), ["斎藤博"])
    }

    func testRetypedWholeSentenceWidensOnlyToName() {
        // 文全体を打ち直した。左は「斎藤」を含めて「は」で、右は「です」で止まる
        let result = HaasCorrectionSuggester.suggestions(
            original: named, corrected: renamed, entries: [entry("斎藤", ["さいとう"])],
            hunks: [HaasEditHunk(originalRange: 0..<named.utf16.count, currentRange: 0..<renamed.utf16.count)])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.kind, .newWord)
        XCTAssertEqual(result.suggestions.first?.before, "斎藤ひろし")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "斎藤博")
        XCTAssertEqual(result.suggestions.first?.reading, "さいとうひろし")
    }

    func testTooLongWidenedChangeFallsBackToWordChange() {
        // 漢字・カタカナの語が続くので文の頭まで広がり、20文字を超える
        let organization = "国立研究開発法人新エネルギー産業技術総合開発機構"
        let original = organization + "斎藤ひろしです。"
        let corrected = organization + "斎藤博です。"
        let whole = HaasEditHunk(originalRange: 0..<original.utf16.count, currentRange: 0..<corrected.utf16.count)
        XCTAssertGreaterThan((organization + "斎藤博").count, HaasCorrectionSuggester.maximumCorrectedLength, "テスト前提")
        let result = HaasCorrectionSuggester.suggestions(
            original: original, corrected: corrected, entries: [], hunks: [whole])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.before, "ひろし")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "博")
    }

    func testEditedSpanChangingDictionaryFormIsStillSkipped() {
        // 辞書の「斎藤」を別の表記に変えた
        let result = HaasCorrectionSuggester.suggestions(
            original: named, corrected: "私の名前は斉藤博です。", entries: [entry("斎藤", ["さいとう"])],
            hunks: [HaasEditHunk(originalRange: 5..<10, currentRange: 5..<8)])
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.usedDictionaryForms, ["斎藤"])
    }

    func testChangesWidenedOverSameWordAreMerged() {
        // 「斉藤東京支店」をまとめて打ち直すと、「東京」を挟む語の差分の2か所が1つになる
        let result = HaasCorrectionSuggester.suggestions(
            original: "斉藤東京支店", corrected: "斎藤東京支社", entries: [],
            hunks: [HaasEditHunk(originalRange: 0..<6, currentRange: 0..<6)])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.before, "斉藤東京支店")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "斎藤東京支社")
        XCTAssertEqual(result.suggestions.first?.reading, "さいとうとうきょうしてん")
    }

    func testFunctionWordsAcrossChangesAreNotMerged() {
        // 「斉藤さんの資料」をまとめて打ち直しても、間の「さん」「の」はひらがななので広げない
        let result = HaasCorrectionSuggester.suggestions(
            original: "斉藤さんの資料です", corrected: "斎藤さんの書類です", entries: [],
            hunks: [HaasEditHunk(originalRange: 0..<7, currentRange: 0..<7)])
        XCTAssertEqual(result.suggestions.map(\.before), ["斉藤", "資料"])
        XCTAssertEqual(result.suggestions.map(\.writtenForm), ["斎藤", "書類"])
    }

    func testDoesNotWidenAcrossSeparatorsBetweenWords() {
        // トークナイザーは「。」「・」空白を語にしないので、語の間に残る。そこを越えて広げない
        for separator in ["。", "・", " "] {
            let original = "斉藤\(separator)東京支店"
            let corrected = "斎藤\(separator)東京支社"
            let result = HaasCorrectionSuggester.suggestions(
                original: original, corrected: corrected, entries: [],
                hunks: [HaasEditHunk(originalRange: 0..<original.utf16.count, currentRange: 0..<corrected.utf16.count)])
            XCTAssertEqual(result.suggestions.map(\.before), ["斉藤", "東京支店"], separator)
            XCTAssertEqual(result.suggestions.map(\.writtenForm), ["斎藤", "東京支社"], separator)
        }
    }

    func testChangingOneOfRepeatedDictionaryFormsIsStillSkipped() {
        // 塊の中の辞書の「斎藤」2つのうち1つを「斉藤」に変えた。もう1つが残っていても候補にしない
        let original = "斎藤東京斎藤ひろし"
        let corrected = "斉藤東京斎藤博"
        let result = HaasCorrectionSuggester.suggestions(
            original: original, corrected: corrected, entries: [entry("斎藤", ["さいとう"])],
            hunks: [HaasEditHunk(originalRange: 0..<original.utf16.count, currentRange: 0..<corrected.utf16.count)])
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.usedDictionaryForms, ["斎藤"])
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
        for surface in ["斎藤", "お願い", "ヒロシ", "ジー", "ABC", "２０２６", "佐々木"] {
            XCTAssertFalse(HaasCorrectionDiff.stopsWidening(surface), surface)
        }
    }

    func testHunkAwayFromChangeLeavesItAsIs() {
        // 「です」を消して打ち直しても、「サイトウ → 斎藤」は広げない
        let result = HaasCorrectionSuggester.suggestions(
            original: "サイトウさんの資料です", corrected: "斎藤さんの資料です", entries: [],
            hunks: [HaasEditHunk(originalRange: 9..<11, currentRange: 7..<9)])
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.before, "サイトウ")
        XCTAssertEqual(result.suggestions.first?.writtenForm, "斎藤")
    }
}
