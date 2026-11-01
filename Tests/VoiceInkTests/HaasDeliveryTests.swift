import AppKit
import XCTest
@testable import VoiceInk

final class HaasDeliveryTests: XCTestCase {
    func testDuplicateCompletionAndPendingCopyDoNotRepeatDeliveredPrefix() {
        var ledger = HaasSegmentLedger()
        XCTAssertTrue(ledger.append(id: "first", text: "VoiceInk と "))
        ledger.setDisposition(.posted, for: "first")
        XCTAssertFalse(ledger.append(id: "first", text: "重複した結果"))
        XCTAssertTrue(ledger.append(id: "second", text: "Amazon Bedrock を使います。"))

        XCTAssertEqual(ledger.fullText, "VoiceInk と Amazon Bedrock を使います。")
        XCTAssertEqual(ledger.pendingText, "Amazon Bedrock を使います。")
        ledger.markPendingAsCopied()
        XCTAssertFalse(ledger.hasUnresolvedSegments)
        XCTAssertNil(ledger.nextPendingSegment)
        XCTAssertEqual(ledger.fullText, "VoiceInk と Amazon Bedrock を使います。")
    }

    func testInterruptedPasteIsRecoveredAsUncertainAndNeverAutomaticallyRetried() throws {
        var original = HaasSegmentLedger()
        original.append(id: "uncertain", text: "JiHAN Prime")
        original.setDisposition(.posting, for: "uncertain")
        original.append(id: "pending", text: "のサービスです。")
        let saved = try JSONEncoder().encode(original)
        var recovered = try JSONDecoder().decode(HaasSegmentLedger.self, from: saved)
        recovered.recoverInterruptedPaste()

        XCTAssertEqual(recovered.uncertainText, "JiHAN Prime")
        XCTAssertEqual(recovered.nextPendingSegment?.id, "pending")
        recovered.acknowledgeUncertainSegments()
        XCTAssertTrue(recovered.uncertainText.isEmpty)
        XCTAssertEqual(recovered.pendingText, "のサービスです。")
    }

    func testAudioQueuedBeforeStopIsDrainedInArrivalOrder() async throws {
        let inbox = HaasAudioInbox()
        let chunks = (0..<40).map { Data([UInt8($0)]) }
        for chunk in chunks { inbox.receive(chunk) }
        inbox.finish()
        var received: [Data] = []
        for try await chunk in inbox.stream { received.append(chunk) }
        XCTAssertEqual(received, chunks)
    }

    func testAudioBacklogFailsInsteadOfSilentlyContinuingWithMissingAudio() async {
        let inbox = HaasAudioInbox()
        for _ in 0..<10_000 { inbox.receive(Data([0, 0])) }
        guard case .audioBacklog? = inbox.failure as? HaasSessionError else {
            return XCTFail("Overflow must report a recoverable recording failure")
        }
        do {
            for try await _ in inbox.stream {}
            XCTFail("An overflowing stream must fail instead of yielding a shortened successful recording")
        } catch {
            guard case .audioBacklog? = error as? HaasSessionError else {
                return XCTFail("Unexpected failure: \(error)")
            }
        }
    }

    @MainActor
    func testCancelledPasteDoesNotChangeClipboardOrPostAnInputCommand() async {
        let changeCount = NSPasteboard.general.changeCount
        let outcome = await CursorPaster.startPasteAtCursor("Haas", shouldPaste: { false }).value
        XCTAssertEqual(outcome.result, .commandNotPosted)
        XCTAssertEqual(NSPasteboard.general.changeCount, changeCount)
    }
}
