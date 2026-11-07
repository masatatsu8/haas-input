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
}
