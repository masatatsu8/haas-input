import XCTest
@testable import VoiceInk

@MainActor
final class CursorPasterReplacementTests: XCTestCase {
    private final class Recorder {
        var checks: [Int] = []
        var backspaces = 0
        var pastes = 0
    }

    private func run(
        deleteCount: Int = 3,
        stopAtCheck: Int? = nil,
        failBackspaceAt: Int? = nil,
        pasteResult: CursorPaster.PasteResult = .commandPosted,
        recorder: Recorder
    ) async -> HaasReplaceOutcome {
        await CursorPaster.runReplacement(
            deleteCount: deleteCount,
            shouldContinue: { deleted in
                recorder.checks.append(deleted)
                return deleted != stopAtCheck
            },
            postBackspace: {
                if recorder.backspaces == failBackspaceAt { return false }
                recorder.backspaces += 1
                return true
            },
            paste: {
                recorder.pastes += 1
                return pasteResult
            }
        )
    }

    func testCompletesAfterAllChecksPass() async {
        let recorder = Recorder()
        let outcome = await run(recorder: recorder)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(recorder.backspaces, 3)
        XCTAssertEqual(recorder.pastes, 1)
        XCTAssertEqual(recorder.checks, [0, 1, 2, 3])
    }

    func testStopsAtFirstCheckBeforeAnyBackspace() async {
        let recorder = Recorder()
        let outcome = await run(stopAtCheck: 0, recorder: recorder)
        XCTAssertEqual(outcome, .notStarted)
        XCTAssertEqual(recorder.backspaces, 0)
        XCTAssertEqual(recorder.pastes, 0)
    }

    func testStopsBeforeSecondBackspace() async {
        let recorder = Recorder()
        let outcome = await run(stopAtCheck: 1, recorder: recorder)
        XCTAssertEqual(outcome, .deletionInterrupted(deleted: 1))
        XCTAssertEqual(recorder.backspaces, 1)
        XCTAssertEqual(recorder.pastes, 0)
    }

    func testStopsJustBeforePaste() async {
        let recorder = Recorder()
        let outcome = await run(stopAtCheck: 3, recorder: recorder)
        XCTAssertEqual(outcome, .deletionInterrupted(deleted: 3))
        XCTAssertEqual(recorder.backspaces, 3)
        XCTAssertEqual(recorder.pastes, 0)
    }

    func testBackspaceFailureReportsDeletedCount() async {
        let recorder = Recorder()
        let outcome = await run(failBackspaceAt: 2, recorder: recorder)
        XCTAssertEqual(outcome, .deletionInterrupted(deleted: 2))
        XCTAssertEqual(recorder.pastes, 0)
    }

    func testPasteNotPostedIsUncertain() async {
        for result in [CursorPaster.PasteResult.commandNotPosted, .commandPartiallyPosted, .clipboardChanged] {
            let recorder = Recorder()
            let outcome = await run(pasteResult: result, recorder: recorder)
            XCTAssertEqual(outcome, .pasteUncertain)
        }
    }

    func testShouldContinueIsNotCalledAfterPaste() async {
        let recorder = Recorder()
        let outcome = await run(recorder: recorder)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(recorder.checks.last, 3)
        XCTAssertEqual(recorder.checks.count, 4)
    }
}
