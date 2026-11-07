import XCTest
@testable import VoiceInk

final class HaasPunctuationFormatterTests: XCTestCase {
    func testFastAddsSentenceEndWithoutChangingExistingTextOrWhitespace() {
        let cases: [(input: String, expected: String)] = [
            ("今日は確認します", "今日は確認します。"),
            ("問題ありません", "問題ありません。"),
            ("確認しました \n", "確認しました。 \n"),
            ("確認済みです。", "確認済みです。"),
            ("確認します、", "確認します、"),
            ("確認します？", "確認します？"),
            ("これで合っていますか", "これで合っていますか？"),
            ("どうでしょうか", "どうでしょうか？"),
            ("確認しましたか \n", "確認しましたか？ \n"),
            ("合っていますか？", "合っていますか？"),
            ("合っていますか。", "合っていますか。"),
            ("そうですかね", "そうですかね"),
            ("この設定を確認したあとで", "この設定を確認したあとで"),
            ("問題ないですが", "問題ないですが"),
            ("次の設定", "次の設定"),
            (" \n", " \n"),
            ("", ""),
        ]

        for item in cases {
            XCTAssertEqual(
                HaasPunctuationFormatter.fast(item.input).unicodeScalars.map(\.value),
                item.expected.unicodeScalars.map(\.value), item.input.debugDescription
            )
        }
    }

    func testNaturalCandidateMustPreserveEveryScalarAndUsePunctuationSafely() {
        let cases: [(name: String, input: String, candidate: String, accepted: Bool)] = [
            ("two sentences", "今日は晴れです明日は雨です", "今日は晴れです。明日は雨です。", true),
            ("names numbers spaces newline", "JiHAN  と ReiHAN を比較します\n料金は1200円 です",
             "JiHAN  と ReiHAN を比較します。\n料金は1200円 です。", true),
            ("existing comma", "これは、確認済みです 次を試します", "これは、確認済みです。 次を試します。", true),
            ("existing punctuation unchanged", "確認済みです。", "確認済みです。", true),
            ("unfinished comma", "確認したあとで", "確認したあとで、", true),
            ("inside closing quote", "「確認します」", "「確認します。」", true),
            ("after closing double quote", "選んだのは\"JiHAN\"", "選んだのは\"JiHAN\"。", true),
            ("after closing single quote", "選んだのは'JiHAN'", "選んだのは'JiHAN'。", true),
            ("apostrophe inside quoted name", "選んだのは'O'Reilly'", "選んだのは'O'Reilly'。", true),
            ("decomposed scalar retained", "Cafe\u{301}です", "Cafe\u{301}です。", true),
            ("emoji retained", "👩‍💻です", "👩‍💻です。", true),
            ("Japanese boundary after name", "JiHANの資料です次を確認します", "JiHANの資料です、次を確認します。", true),
            ("separate Latin words", "JiHAN ReiHANを比較します", "JiHAN、 ReiHANを比較します。", true),
            ("question mark after ka", "合っていますか次に進みます", "合っていますか？次に進みます。", true),
            ("question mark inside closing quote", "「合っていますか」", "「合っていますか？」", true),
            ("question mark after non-ka", "確認します", "確認します？", false),
            ("ASCII question mark", "合っていますか", "合っていますか?", false),
            ("question mark followed by full stop", "合っていますか", "合っていますか？。", false),
            ("question mark next to existing full stop", "合っていますか。", "合っていますか？。", false),
            ("name split by punctuation", "JiHANの資料です", "Ji、HANの資料です。", false),
            ("number split by punctuation", "料金は1200円です", "料金は1、200円です。", false),
            ("fullwidth name split", "ＪｉＨＡＮの資料です", "Ｊｉ、ＨＡＮの資料です。", false),
            ("fullwidth number split", "料金は１２００円です", "料金は１、２００円です。", false),
            ("alphanumeric name split", "RX100を使います", "RX、100を使います。", false),
            ("hyphenated identifier split", "GPT-4を使います", "GPT-、4を使います。", false),
            ("underscore identifier split", "foo_barを使います", "foo_、barを使います。", false),
            ("fullwidth underscore identifier split", "Ａ＿Ｂを使います", "Ａ＿、Ｂを使います。", false),
            ("fullwidth hyphenated identifier split", "Ａ－Ｂを使います", "Ａ－、Ｂを使います。", false),
            ("name case changed", "JiHAN は16台です", "JIHAN は16台です。", false),
            ("number changed", "料金は1200円です", "料金は1000円です。", false),
            ("ASCII comma added", "料金は1200円です", "料金は1,200円です。", false),
            ("whitespace removed", "JiHAN  の試作です\nReiHAN は3台です", "JiHANの試作です。ReiHANは3台です。", false),
            ("newline added", "確認します", "確認します。\n", false),
            ("source suffix omitted", "確認します", "確認。", false),
            ("explanation added", "確認します", "修正結果: 確認します。", false),
            ("code fence added", "確認します", "```\n確認します。\n```", false),
            ("leading comma", "確認します", "、確認します。", false),
            ("comma after opening quote", "「確認します」", "「、確認します。」", false),
            ("comma after opening quote in sentence", "次は「確認します」", "次は「、確認します」", false),
            ("comma after opening quote and spaces", "次は「  確認します」", "次は「  、確認します」", false),
            ("comma after opening double quote", "次は\"確認します\"", "次は\"、確認します\"", false),
            ("comma after opening single quote and spaces", "次は'  確認します'", "次は'  、確認します'", false),
            ("word apostrophe before opening quote", "O'Reillyでは'  確認します'", "O'Reillyでは'  、確認します'", false),
            ("comma before word apostrophe", "O'Reillyです", "O、'Reillyです。", false),
            ("comma after word apostrophe", "O'Reillyです", "O'、Reillyです。", false),
            ("comma followed by full stop", "確認します", "確認します、。", false),
            ("adjacent across whitespace", "確認します 次も試します", "確認します。 、次も試します。", false),
            ("adjacent to existing mark", "確認します。", "確認します、。", false),
            ("unfinished full stop", "確認したあとで", "確認したあとで。", false),
            ("quoted unfinished full stop", "「確認したあとで」", "「確認したあとで。」", false),
            ("normalization changed scalars", "Cafe\u{301}です", "Caféです。", false),
            ("combining sequence split", "Cafe\u{301}です", "Cafe、\u{301}です。", false),
            ("emoji sequence split", "👩‍💻です", "👩、‍💻です。", false),
        ]

        for item in cases {
            let result = HaasPunctuationFormatter.validatedCandidate(item.candidate, preserving: item.input)
            if item.accepted {
                XCTAssertEqual(result?.unicodeScalars.map(\.value), item.candidate.unicodeScalars.map(\.value), item.name)
            } else {
                XCTAssertNil(result, item.name)
            }
        }
    }
    func testHeldPeriodIsSplitOnlyWhenItIsTheLastScalar() {
        let cases: [(input: String, body: String, held: Bool)] = [
            ("確認します。", "確認します", true),
            ("です。", "です", true),
            ("「確認します。」", "「確認します。」", false),
            ("確認します。」", "確認します。」", false),
            ("完了です。\n", "完了です。\n", false),
            ("完了です。 ", "完了です。 ", false),
            ("合っていますか？", "合っていますか？", false),
            ("すごい！", "すごい！", false),
            ("確認します", "確認します", false),
            ("。", "。", false),
            (" 。", " 。", false),
            ("", "", false),
        ]

        for item in cases {
            let result = HaasPunctuationFormatter.splittingHeldPeriod(item.input)
            XCTAssertEqual(result.body.unicodeScalars.map(\.value), item.body.unicodeScalars.map(\.value), item.input.debugDescription)
            XCTAssertEqual(result.held, item.held, item.input.debugDescription)
        }
    }

    func testNextSegmentStartsSentenceUnlessItContinuesThePreviousOne() {
        let cases: [(next: String, startsSentence: Bool)] = [
            ("それで", true),
            ("次に進みます", true),
            ("けど", false),
            ("けど次も確認します", false),
            ("けれど", false),
            ("けれども", false),
            ("けども", false),
            ("ので", false),
            ("ので確認しました", false),
            ("って言ってました", false),
            ("とか", false),
            ("  けど", false),
            ("ね", false),
            ("よね", false),
            ("よ", false),
            ("ねえ", false),
            ("な", false),
            ("なあ", false),
            ("か", false),
            (" ね ", false),
            ("ねこ", true),
            ("学校", true),
            ("なので", true),
            ("よろしくお願いします", true),
            ("よく分かりました", true),
            ("から揚げ", true),
            ("、それで", false),
            ("。それで", false),
            ("，それで", false),
            ("．それで", false),
            ("？", false),
            ("！", false),
            ("?", false),
            ("!", false),
            (" 、それで", false),
            (" ", true),
        ]

        for item in cases {
            XCTAssertEqual(HaasPunctuationFormatter.startsSentence(item.next), item.startsSentence, item.next.debugDescription)
        }
    }

    func testHeldPeriodJoinsOrSeparatesTheNextSegment() {
        func joined(_ previous: String, _ next: String) -> String {
            let split = HaasPunctuationFormatter.splittingHeldPeriod(HaasPunctuationFormatter.fast(previous))
            guard split.held, HaasPunctuationFormatter.startsSentence(next) else { return split.body + next }
            return split.body + HaasPunctuationFormatter.attachingHeldPeriod(to: next)
        }
        XCTAssertEqual(joined("確認したいです", "けど"), "確認したいですけど")
        XCTAssertEqual(joined("確認したいです", "それで"), "確認したいです。それで")
        XCTAssertEqual(joined("確認したいです", "、それで"), "確認したいです、それで")
        XCTAssertEqual(joined("確認したいです", "ね"), "確認したいですね")
    }

    func testAttachingHeldPeriodNeverDoublesPunctuation() {
        let cases: [(text: String, expected: String)] = [
            ("それで", "。それで"),
            (" それで", "。 それで"),
            ("。それで", "。それで"),
            ("、それで", "、それで"),
            (" 。それで", " 。それで"),
            ("？", "？"),
            ("!", "!"),
        ]

        for item in cases {
            XCTAssertEqual(HaasPunctuationFormatter.attachingHeldPeriod(to: item.text), item.expected, item.text.debugDescription)
        }
    }
}
