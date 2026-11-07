import XCTest
@testable import VoiceInk

final class HaasProofreadValidatorTests: XCTestCase {
    func testAcceptsSmallCorrectionsAndPunctuation() {
        XCTAssertEqual(HaasProofreadValidator.validatedCandidate(
            "このアプリは音声を端末内で処理します。", preserving: "このアプリは音声を端末ないで処理します", protectedTerms: []),
            "このアプリは音声を端末内で処理します。")
    }

    func testAcceptsQuestionMarkAddedToQuestion() {
        XCTAssertEqual(HaasProofreadValidator.validatedCandidate(
            "これで合っていますか？", preserving: "これで合っていますか", protectedTerms: []),
            "これで合っていますか？")
        XCTAssertEqual(HaasProofreadValidator.validatedCandidate(
            "これは端末内で処理しますか？", preserving: "これは端末ないで処理しますか", protectedTerms: []),
            "これは端末内で処理しますか？")
    }

    func testRejectsLargeRewritesAndAddedLines() {
        XCTAssertNil(HaasProofreadValidator.validatedCandidate(
            "会議は延期です。", preserving: "来週の打ち合わせは火曜日の午後に変更になりました", protectedTerms: []))
        XCTAssertNil(HaasProofreadValidator.validatedCandidate(
            "校正結果:\n端末内で処理します", preserving: "端末ないで処理します", protectedTerms: []))
        XCTAssertNil(HaasProofreadValidator.validatedCandidate("", preserving: "端末ないで", protectedTerms: []))
    }

    func testRejectsChangedDigitsLatinTextAndProtectedTerms() {
        XCTAssertNil(HaasProofreadValidator.validatedCandidate(
            "会議は4時からです", preserving: "会議は3時からです", protectedTerms: []))
        XCTAssertNil(HaasProofreadValidator.validatedCandidate(
            "jihan primeの資料です", preserving: "JiHAN Primeの資料です", protectedTerms: []))
        XCTAssertNil(HaasProofreadValidator.validatedCandidate(
            "辰巳さんの資料です", preserving: "巽さんの資料です", protectedTerms: ["巽"]))
        XCTAssertNil(HaasProofreadValidator.validatedCandidate("予算は3万円です", preserving: "予算は-3万円です", protectedTerms: []))
        XCTAssertNil(HaasProofreadValidator.validatedCandidate("値は3/5です", preserving: "値は3.5です", protectedTerms: []))
        XCTAssertNil(HaasProofreadValidator.validatedCandidate("foo-barを使います", preserving: "foo_barを使います", protectedTerms: []))
        XCTAssertEqual(HaasProofreadValidator.validatedCandidate("値は3.5です。", preserving: "値は３．５です", protectedTerms: []),
                       "値は3.5です。")
    }

    func testDropsTrailingPeriodAfterUnfinishedEnding() {
        for (original, candidate, expected) in [
            ("確認してから", "確認してから。", "確認してから"),
            ("確認したので", "確認したので。", "確認したので"),
            ("端末ないで処理してから", "端末内で処理してから。", "端末内で処理してから"),
            ("確認したので」", "確認したので。」", "確認したので」"),
        ] {
            XCTAssertEqual(HaasProofreadValidator.validatedCandidate(
                candidate, preserving: original, protectedTerms: []), expected, original)
        }
    }

    func testKeepsPeriodOnFinishedSentence() {
        XCTAssertEqual(HaasProofreadValidator.validatedCandidate(
            "確認します。", preserving: "確認します", protectedTerms: []), "確認します。")
    }

    func testRejectsCandidateThatBecomesEmptyAfterPeriodRemoval() {
        XCTAssertNil(HaasProofreadValidator.validatedCandidate("。", preserving: "して", protectedTerms: []))
    }
}
