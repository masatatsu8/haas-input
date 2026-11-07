import XCTest
@testable import VoiceInk

@MainActor
final class CursorPasterReplacementTests: XCTestCase {
    private final class Recorder {
        var checks: [Int] = []
        var backspaces = 0
        var pastes = 0
        var events: [String] = []
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
                recorder.events.append("check\(deleted)")
                return deleted != stopAtCheck
            },
            postBackspace: {
                if recorder.backspaces == failBackspaceAt { return false }
                recorder.backspaces += 1
                recorder.events.append("backspace")
                return true
            },
            paste: {
                recorder.pastes += 1
                recorder.events.append("paste")
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
        XCTAssertEqual(recorder.checks, [0, 1, 2])
        XCTAssertEqual(recorder.backspaces, 2)
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
        XCTAssertEqual(
            recorder.events,
            ["check0", "backspace", "check1", "backspace", "check2", "backspace", "check3", "paste"])
    }

    func testWaitsForModifierReleaseBeforeFirstCheck() async {
        let recorder = Recorder()
        let outcome = await CursorPaster.runReplacement(
            deleteCount: 2,
            beforeFirstBackspace: {
                recorder.events.append("wait")
                return true
            },
            shouldContinue: { deleted in
                recorder.events.append("check\(deleted)")
                return true
            },
            postBackspace: {
                recorder.events.append("backspace")
                return true
            },
            paste: {
                recorder.events.append("paste")
                return .commandPosted
            })
        XCTAssertEqual(outcome, .completed)
        // 待ちは最初の確認より前に1度だけ。待った後に欄を確かめてから消す
        XCTAssertEqual(recorder.events, ["wait", "check0", "backspace", "check1", "backspace", "check2", "paste"])
    }

    func testModifierWaitFailureStopsBeforeAnything() async {
        let recorder = Recorder()
        let outcome = await CursorPaster.runReplacement(
            deleteCount: 3,
            beforeFirstBackspace: { false },
            shouldContinue: { deleted in
                recorder.checks.append(deleted)
                return true
            },
            postBackspace: {
                recorder.backspaces += 1
                return true
            },
            paste: {
                recorder.pastes += 1
                return .commandPosted
            })
        XCTAssertEqual(outcome, .notStarted)
        XCTAssertTrue(recorder.checks.isEmpty)
        XCTAssertEqual(recorder.backspaces, 0)
        XCTAssertEqual(recorder.pastes, 0)
    }

    func testModifierWaitProceedsOnceCommandIsReleased() async {
        // ⌘↩ の ⌘ が2回読む間だけ押されたまま、その後に離れる
        var reads = 0
        let released = await CursorPaster.waitForModifiersReleased(
            flags: {
                reads += 1
                return reads <= 2 ? [.maskCommand] : [.maskShift]
            },
            timeout: .seconds(1), pollInterval: .milliseconds(1))
        XCTAssertTrue(released)
        XCTAssertEqual(reads, 3)
    }

    func testModifierWaitTimesOutWhileOptionOrControlIsHeld() async {
        for held in [CGEventFlags.maskAlternate, .maskControl, .maskCommand] {
            var reads = 0
            let started = ContinuousClock.now
            let released = await CursorPaster.waitForModifiersReleased(
                flags: {
                    reads += 1
                    return held
                },
                timeout: .milliseconds(40), pollInterval: .milliseconds(5))
            XCTAssertFalse(released, "\(held)")
            XCTAssertGreaterThan(reads, 1, "期限まで読み直す")
            XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(40))
        }
    }

    func testModifierTimeoutMakesReplacementNotStarted() async {
        let recorder = Recorder()
        let outcome = await CursorPaster.runReplacement(
            deleteCount: 3,
            beforeFirstBackspace: {
                await CursorPaster.waitForModifiersReleased(
                    flags: { [.maskCommand] }, timeout: .milliseconds(30), pollInterval: .milliseconds(5))
            },
            shouldContinue: { _ in true },
            postBackspace: {
                recorder.backspaces += 1
                return true
            },
            paste: {
                recorder.pastes += 1
                return .commandPosted
            })
        XCTAssertEqual(outcome, .notStarted)
        XCTAssertEqual(recorder.backspaces, 0)
        XCTAssertEqual(recorder.pastes, 0)
    }

    func testZeroDeleteCountChecksOnceThenPastes() async {
        let recorder = Recorder()
        let outcome = await run(deleteCount: 0, recorder: recorder)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(recorder.events, ["check0", "paste"])
    }
}
