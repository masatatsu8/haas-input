import XCTest
@testable import VoiceInk

private func readable(_ before: String, after: String = "", selection: Int = 0) -> HaasFieldState {
    .readable(textBeforeCaret: before, textAfterCaret: after, selectionLength: selection)
}

final class HaasReplacementDecisionTests: XCTestCase {
    private func context(
        inserted: String = "合っていますか",
        allPosted: Bool = true,
        watched: Bool = true,
        unchanged: Bool = true,
        field: HaasFieldState = readable("前の文。合っていますか"),
        baseline: HaasInsertionBaseline? = .readable(textBeforeInsertion: "前の文。", textAfterInsertion: "")
    ) -> HaasReplacementContext {
        HaasReplacementContext(
            insertedText: inserted, allSegmentsPosted: allPosted,
            watchedWithoutUserInput: watched, targetUnchanged: unchanged, field: field,
            insertionBaseline: baseline
        )
    }


    func testEmptyInsertedTextIsNoRecord() {
        XCTAssertEqual(HaasReplacementDecision.decide(context(inserted: "")), .copyOnly(.noRecord))
    }

    func testNotAllPosted() {
        XCTAssertEqual(HaasReplacementDecision.decide(context(allPosted: false)), .copyOnly(.notAllPosted))
    }

    func testUserInputDetected() {
        XCTAssertEqual(HaasReplacementDecision.decide(context(watched: false)), .copyOnly(.userInputDetected))
    }

    func testTargetChanged() {
        XCTAssertEqual(HaasReplacementDecision.decide(context(unchanged: false)), .copyOnly(.targetChanged))
    }

    func testSelectionNotEmpty() {
        let field = readable("前の文。合っていますか", selection: 1)
        XCTAssertEqual(HaasReplacementDecision.decide(context(field: field)), .copyOnly(.selectionNotEmpty))
    }

    func testReadableMatchReplacesAutomatically() {
        XCTAssertEqual(HaasReplacementDecision.decide(context()), .replaceAutomatically(deleteCount: 7))
    }

    func testReadableMismatch() {
        let field = readable("合っています")
        XCTAssertEqual(HaasReplacementDecision.decide(context(field: field)), .copyOnly(.textMismatch))
    }

    func testMatchingSuffixAloneDoesNotProveInsertion() {
        // 文字数の上限で貼り付けが無視され、欄が元から入れた文と同じ文で終わっている
        let field = readable("はい")
        XCTAssertEqual(
            HaasReplacementDecision.decide(
                context(inserted: "はい", field: field, baseline: .readable(textBeforeInsertion: "はい", textAfterInsertion: ""))),
            .copyOnly(.textMismatch))
        // 貼る前の中身に入れた文を足したものと一致すれば消せる
        XCTAssertEqual(
            HaasReplacementDecision.decide(
                context(inserted: "はい", field: readable("はいはい"), baseline: .readable(textBeforeInsertion: "はい", textAfterInsertion: ""))),
            .replaceAutomatically(deleteCount: 2))
    }

    func testTextAfterCaretMustMatchRecordedPosition() {
        // 貼る前は「前|はい後」。貼り付けが拒まれ、カーソルだけが既存の「はい」の後ろへ動いた
        let baseline = HaasInsertionBaseline.readable(textBeforeInsertion: "前", textAfterInsertion: "はい後")
        XCTAssertEqual(
            HaasReplacementDecision.decide(
                context(inserted: "はい", field: readable("前はい", after: "後"), baseline: baseline)),
            .copyOnly(.textMismatch))
        // 記録した位置に入れた文だけが増えていれば消せる
        XCTAssertEqual(
            HaasReplacementDecision.decide(
                context(inserted: "はい", field: readable("前はい", after: "はい後"), baseline: baseline)),
            .replaceAutomatically(deleteCount: 2))
    }

    func testReadableFieldWithoutBaselineOnlyCopies() {
        XCTAssertEqual(HaasReplacementDecision.decide(context(baseline: nil)), .copyOnly(.insertionUnverified))
        XCTAssertEqual(
            HaasReplacementDecision.decide(context(field: .unreadable, baseline: nil)), .copyOnly(.insertionUnverified))
    }

    func testFieldUnreadableAtInsertionButReadableNowOnlyCopies() {
        XCTAssertEqual(
            HaasReplacementDecision.decide(context(baseline: .unreadable)), .copyOnly(.insertionUnverified))
        // 今も読めなければ、確認付きの置き換えのまま
        XCTAssertEqual(
            HaasReplacementDecision.decide(context(field: .unreadable, baseline: .unreadable)),
            .replaceAfterConfirmation(deleteCount: 7))
    }

    func testReadableMultilineMatchReplacesAutomatically() {
        let field = readable("前\nA\nB")
        XCTAssertEqual(
            HaasReplacementDecision.decide(
                context(inserted: "A\nB", field: field, baseline: .readable(textBeforeInsertion: "前\n", textAfterInsertion: ""))),
            .replaceAutomatically(deleteCount: 3)
        )
    }

    func testUnreadableSingleLineNeedsConfirmation() {
        XCTAssertEqual(
            HaasReplacementDecision.decide(context(field: .unreadable)),
            .replaceAfterConfirmation(deleteCount: 7)
        )
    }

    func testUnreadableMultiline() {
        XCTAssertEqual(
            HaasReplacementDecision.decide(context(inserted: "一行目\n二行目", field: .unreadable)),
            .copyOnly(.multiline)
        )
    }

    func testUnreadableLengthLimit() {
        XCTAssertEqual(
            HaasReplacementDecision.decide(context(inserted: String(repeating: "あ", count: 201), field: .unreadable)),
            .copyOnly(.tooLong)
        )
        XCTAssertEqual(
            HaasReplacementDecision.decide(context(inserted: String(repeating: "あ", count: 200), field: .unreadable)),
            .replaceAfterConfirmation(deleteCount: 200)
        )
    }

    func testEmojiSequenceCountsAsOneCharacter() {
        let field = readable("👩‍💻です")
        XCTAssertEqual(
            HaasReplacementDecision.decide(
                context(inserted: "👩‍💻です", field: field, baseline: .readable(textBeforeInsertion: "", textAfterInsertion: ""))),
            .replaceAutomatically(deleteCount: 3)
        )
    }

    func testConfirmedKeepsSameAutomatic() {
        XCTAssertEqual(
            HaasReplacementDecision.confirmed(shown: .replaceAutomatically(deleteCount: 7), now: .replaceAutomatically(deleteCount: 7)),
            .replaceAutomatically(deleteCount: 7)
        )
    }

    func testConfirmedRejectsAutomaticTurnedConfirmation() {
        XCTAssertEqual(
            HaasReplacementDecision.confirmed(shown: .replaceAutomatically(deleteCount: 7), now: .replaceAfterConfirmation(deleteCount: 7)),
            .copyOnly(.targetChanged)
        )
    }

    func testConfirmedKeepsSameConfirmation() {
        XCTAssertEqual(
            HaasReplacementDecision.confirmed(shown: .replaceAfterConfirmation(deleteCount: 7), now: .replaceAfterConfirmation(deleteCount: 7)),
            .replaceAfterConfirmation(deleteCount: 7)
        )
    }

    func testConfirmedReturnsNowCopyOnly() {
        XCTAssertEqual(
            HaasReplacementDecision.confirmed(shown: .replaceAutomatically(deleteCount: 7), now: .copyOnly(.userInputDetected)),
            .copyOnly(.userInputDetected)
        )
    }

    private let expectation = HaasFieldExpectation(
        textBeforeInsertion: "前の文。", insertedText: "合っていますか", textAfterCaret: "後ろの文")

    func testFieldMatchesProgress() {
        XCTAssertTrue(HaasReplacementDecision.fieldMatchesProgress(
            readable("前の文。合っていま", after: "後ろの文"), expectation: expectation, deleted: 2))
        XCTAssertFalse(HaasReplacementDecision.fieldMatchesProgress(
            readable("前の文。合っていま", after: "後ろの文", selection: 1), expectation: expectation, deleted: 2))
        XCTAssertFalse(HaasReplacementDecision.fieldMatchesProgress(
            readable("前の文。合ってい", after: "後ろの文"), expectation: expectation, deleted: 2))
        XCTAssertFalse(HaasReplacementDecision.fieldMatchesProgress(
            .unreadable, expectation: expectation, deleted: 2))
    }

    func testFieldMatchesProgressNeedsSameTextAfterCaret() {
        // 前は合っていても、カーソルの後ろが開いたときと違えば止める (後ろの文字まで消えた)
        XCTAssertFalse(HaasReplacementDecision.fieldMatchesProgress(
            readable("前の文。合っていま", after: "ろの文"), expectation: expectation, deleted: 2))
        XCTAssertFalse(HaasReplacementDecision.fieldMatchesProgress(
            readable("前の文。合っていま", after: ""), expectation: expectation, deleted: 2))
    }

    func testBackspaceMayDeleteBeyondCaretForPairs() {
        let pairs: [(String, String)] = [
            ("(", ")"), ("[", "]"), ("{", "}"), ("「", "」"), ("『", "』"), ("\"", "\""), ("'", "'"),
        ]
        for (open, close) in pairs {
            XCTAssertTrue(
                HaasReplacementDecision.backspaceMayDeleteBeyondCaret(readable("f\(open)", after: "\(close)後")),
                "\(open)\(close)")
            // 閉じ側が直後になければ消してよい
            XCTAssertFalse(
                HaasReplacementDecision.backspaceMayDeleteBeyondCaret(readable("f\(open)", after: "x\(close)")),
                "\(open)\(close)")
        }
        XCTAssertFalse(HaasReplacementDecision.backspaceMayDeleteBeyondCaret(readable("f(", after: "]")))
        XCTAssertFalse(HaasReplacementDecision.backspaceMayDeleteBeyondCaret(readable("あ", after: ")")))
        XCTAssertFalse(HaasReplacementDecision.backspaceMayDeleteBeyondCaret(.unreadable))
    }

    // MARK: - 消している途中の読み直し

    @MainActor
    private func awaitProgress(
        deleted: Int, window: Duration = .milliseconds(150), states: [HaasFieldState], reads: inout Int
    ) async -> Bool {
        var count = 0
        let result = await HaasCorrectionCoordinator.awaitFieldProgress(
            expectation: HaasFieldExpectation(
                textBeforeInsertion: "前の文。", insertedText: "合っていますか", textAfterCaret: ""),
            deleted: deleted,
            readField: {
                defer { count += 1 }
                return states[min(count, states.count - 1)]
            },
            window: window, pollInterval: .milliseconds(1))
        reads = count
        return result
    }

    @MainActor
    func testStaleFieldThenUpdatedProceeds() async {
        // 2文字目を消した直後、欄はまだ1文字消した状態を2回返し、その後に追いつく
        let stale = readable("前の文。合っています")
        let updated = readable("前の文。合っていま")
        var reads = 0
        let proceeds = await awaitProgress(deleted: 2, states: [stale, stale, updated], reads: &reads)
        XCTAssertTrue(proceeds)
        XCTAssertEqual(reads, 3)
    }

    @MainActor
    func testStaleFieldUntilTimeoutStops() async {
        let stale = readable("前の文。合っています")
        var reads = 0
        let started = ContinuousClock.now
        let proceeds = await awaitProgress(deleted: 2, window: .milliseconds(40), states: [stale], reads: &reads)
        XCTAssertFalse(proceeds)
        XCTAssertGreaterThan(reads, 1)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(40))
    }

    @MainActor
    func testUnexpectedFieldStopsAtOnce() async {
        let unexpected: [HaasFieldState] = [
            // 2文字消えている (1文字多い)
            readable("前の文。合ってい"),
            // 利用者が文字を足した
            readable("前の文。合っていますx"),
            // 前の段階の中身でも、選択があれば待たない
            readable("前の文。合っています", selection: 1),
            // 前の段階の中身でも、カーソルの後ろが変われば待たない
            readable("前の文。合っています", after: ")"),
            .unreadable,
        ]
        for state in unexpected {
            var reads = 0
            let proceeds = await awaitProgress(deleted: 2, states: [state], reads: &reads)
            XCTAssertFalse(proceeds, "\(state)")
            XCTAssertEqual(reads, 1, "\(state)")
        }
    }

    @MainActor
    func testFirstCheckHasNoPreviousStepToWaitFor() async {
        // 消す前 (deleted == 0) の欄が入れた文と合わなければ、待たずに止める
        var reads = 0
        let proceeds = await awaitProgress(deleted: 0, states: [readable("前の文。合っていま")], reads: &reads)
        XCTAssertFalse(proceeds)
        XCTAssertEqual(reads, 1)
        let matches = await awaitProgress(deleted: 0, states: [readable("前の文。合っていますか")], reads: &reads)
        XCTAssertTrue(matches)
    }
}
