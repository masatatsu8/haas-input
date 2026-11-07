import XCTest
@testable import VoiceInk

final class HaasReplacementDecisionTests: XCTestCase {
    private func context(
        inserted: String = "合っていますか",
        allPosted: Bool = true,
        watched: Bool = true,
        unchanged: Bool = true,
        field: HaasFieldState = .readable(textBeforeCaret: "前の文。合っていますか", selectionLength: 0)
    ) -> HaasReplacementContext {
        HaasReplacementContext(
            insertedText: inserted, allSegmentsPosted: allPosted,
            watchedWithoutUserInput: watched, targetUnchanged: unchanged, field: field
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
        let field = HaasFieldState.readable(textBeforeCaret: "前の文。合っていますか", selectionLength: 1)
        XCTAssertEqual(HaasReplacementDecision.decide(context(field: field)), .copyOnly(.selectionNotEmpty))
    }

    func testReadableMatchReplacesAutomatically() {
        XCTAssertEqual(HaasReplacementDecision.decide(context()), .replaceAutomatically(deleteCount: 7))
    }

    func testReadableMismatch() {
        let field = HaasFieldState.readable(textBeforeCaret: "合っています", selectionLength: 0)
        XCTAssertEqual(HaasReplacementDecision.decide(context(field: field)), .copyOnly(.textMismatch))
    }

    func testReadableMultilineMatchReplacesAutomatically() {
        let field = HaasFieldState.readable(textBeforeCaret: "前\nA\nB", selectionLength: 0)
        XCTAssertEqual(
            HaasReplacementDecision.decide(context(inserted: "A\nB", field: field)),
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
        let field = HaasFieldState.readable(textBeforeCaret: "👩‍💻です", selectionLength: 0)
        XCTAssertEqual(
            HaasReplacementDecision.decide(context(inserted: "👩‍💻です", field: field)),
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

    func testFieldMatchesProgress() {
        let before = "前の文。"
        let inserted = "合っていますか"
        XCTAssertTrue(HaasReplacementDecision.fieldMatchesProgress(
            .readable(textBeforeCaret: "前の文。合っていま", selectionLength: 0),
            textBeforeInsertion: before, insertedText: inserted, deleted: 2))
        XCTAssertFalse(HaasReplacementDecision.fieldMatchesProgress(
            .readable(textBeforeCaret: "前の文。合っていま", selectionLength: 1),
            textBeforeInsertion: before, insertedText: inserted, deleted: 2))
        XCTAssertFalse(HaasReplacementDecision.fieldMatchesProgress(
            .readable(textBeforeCaret: "前の文。合ってい", selectionLength: 0),
            textBeforeInsertion: before, insertedText: inserted, deleted: 2))
        XCTAssertFalse(HaasReplacementDecision.fieldMatchesProgress(
            .unreadable, textBeforeInsertion: before, insertedText: inserted, deleted: 2))
    }

    // MARK: - 消している途中の読み直し

    private func awaitProgress(
        deleted: Int, window: Duration = .milliseconds(150), states: [HaasFieldState], reads: inout Int
    ) async -> Bool {
        var count = 0
        let result = await HaasReplacementDecision.awaitFieldProgress(
            textBeforeInsertion: "前の文。", insertedText: "合っていますか", deleted: deleted,
            readField: {
                defer { count += 1 }
                return states[min(count, states.count - 1)]
            },
            window: window, pollInterval: .milliseconds(1))
        reads = count
        return result
    }

    func testStaleFieldThenUpdatedProceeds() async {
        // 2文字目を消した直後、欄はまだ1文字消した状態を2回返し、その後に追いつく
        let stale = HaasFieldState.readable(textBeforeCaret: "前の文。合っています", selectionLength: 0)
        let updated = HaasFieldState.readable(textBeforeCaret: "前の文。合っていま", selectionLength: 0)
        var reads = 0
        let proceeds = await awaitProgress(deleted: 2, states: [stale, stale, updated], reads: &reads)
        XCTAssertTrue(proceeds)
        XCTAssertEqual(reads, 3)
    }

    func testStaleFieldUntilTimeoutStops() async {
        let stale = HaasFieldState.readable(textBeforeCaret: "前の文。合っています", selectionLength: 0)
        var reads = 0
        let started = ContinuousClock.now
        let proceeds = await awaitProgress(deleted: 2, window: .milliseconds(40), states: [stale], reads: &reads)
        XCTAssertFalse(proceeds)
        XCTAssertGreaterThan(reads, 1)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(40))
    }

    func testUnexpectedFieldStopsAtOnce() async {
        let unexpected: [HaasFieldState] = [
            // 2文字消えている (1文字多い)
            .readable(textBeforeCaret: "前の文。合ってい", selectionLength: 0),
            // 利用者が文字を足した
            .readable(textBeforeCaret: "前の文。合っていますx", selectionLength: 0),
            // 前の段階の中身でも、選択があれば待たない
            .readable(textBeforeCaret: "前の文。合っています", selectionLength: 1),
            .unreadable,
        ]
        for state in unexpected {
            var reads = 0
            let proceeds = await awaitProgress(deleted: 2, states: [state], reads: &reads)
            XCTAssertFalse(proceeds, "\(state)")
            XCTAssertEqual(reads, 1, "\(state)")
        }
    }

    func testFirstCheckHasNoPreviousStepToWaitFor() async {
        // 消す前 (deleted == 0) の欄が入れた文と合わなければ、待たずに止める
        var reads = 0
        let proceeds = await awaitProgress(
            deleted: 0, states: [.readable(textBeforeCaret: "前の文。合っていま", selectionLength: 0)], reads: &reads)
        XCTAssertFalse(proceeds)
        XCTAssertEqual(reads, 1)
        let matches = await awaitProgress(
            deleted: 0, states: [.readable(textBeforeCaret: "前の文。合っていますか", selectionLength: 0)],
            reads: &reads)
        XCTAssertTrue(matches)
    }
}
