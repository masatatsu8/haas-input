import Foundation
import XCTest
@testable import VoiceInk

@MainActor
final class HaasPunctuationWorkerTests: XCTestCase {
    func testOnlyOneNativeRequestRunsAndTheSlotReopensAfterCompletion() async throws {
        let generator = ControlledPunctuationGenerator()
        defer { generator.cancelPending() }
        let worker = HaasPunctuationWorker(generator: generator, timeout: .seconds(2))
        let firstStarted = expectation(description: "First native request started")
        let firstCompleted = expectation(description: "First completion")
        generator.onStarted = { _ in firstStarted.fulfill() }
        var firstResults: [String?] = []
        XCTAssertTrue(worker.submit("最初です", requestID: UUID()) {
            firstResults.append($0)
            firstCompleted.fulfill()
        })
        await fulfillment(of: [firstStarted], timeout: 1)
        XCTAssertFalse(worker.submit("まだ開始しません", requestID: UUID()) { _ in
            XCTFail("A declined request must not complete")
        })
        XCTAssertEqual(generator.requests, ["最初です"])

        try generator.complete(index: 0, result: .success("最初です。"))
        await fulfillment(of: [firstCompleted], timeout: 1)
        XCTAssertEqual(firstResults, ["最初です。"])

        let nextStarted = expectation(description: "Next native request started")
        let nextCompleted = expectation(description: "Next completion")
        generator.onStarted = { _ in nextStarted.fulfill() }
        var nextResults: [String?] = []
        XCTAssertTrue(worker.submit("次です", requestID: UUID()) {
            nextResults.append($0)
            nextCompleted.fulfill()
        })
        await fulfillment(of: [nextStarted], timeout: 1)
        try generator.complete(index: 1, result: .success("次です。"))
        await fulfillment(of: [nextCompleted], timeout: 1)
        XCTAssertEqual(nextResults, ["次です。"])
        XCTAssertEqual(generator.requests, ["最初です", "次です"])
    }

    func testDeadlineFallsBackOnceButKeepsSlotUntilNativeExit() async throws {
        let generator = ControlledPunctuationGenerator()
        defer { generator.cancelPending() }
        let worker = HaasPunctuationWorker(generator: generator, timeout: .milliseconds(200))
        let started = expectation(description: "Native work started")
        let expired = expectation(description: "Deadline reports fallback")
        let exited = expectation(description: "Cancelled native work eventually exits")
        generator.onStarted = { _ in started.fulfill() }
        generator.onExited = { _ in exited.fulfill() }
        var results: [String?] = []
        XCTAssertTrue(worker.submit("待っています", requestID: UUID()) {
            results.append($0)
            expired.fulfill()
        })
        await fulfillment(of: [started, expired], timeout: 1)
        XCTAssertEqual(results, [nil])
        XCTAssertFalse(worker.submit("重ねません", requestID: UUID()) { _ in
            XCTFail("Timeout must not make unfinished native work disappear")
        })
        XCTAssertEqual(generator.requests, ["待っています"])

        try generator.complete(index: 0, result: .success("待っています。"))
        await fulfillment(of: [exited], timeout: 1)
        XCTAssertEqual(generator.cancelledAtExit[0], true)
        XCTAssertEqual(results, [nil], "A late native result must not complete a timed-out request twice")

        generator.onExited = nil
        let nextStarted = expectation(description: "Slot reused after actual exit")
        let nextCompleted = expectation(description: "Next request completes")
        generator.onStarted = { _ in nextStarted.fulfill() }
        XCTAssertTrue(worker.submit("再開します", requestID: UUID()) { candidate in
            XCTAssertEqual(candidate, "再開します。")
            nextCompleted.fulfill()
        })
        await fulfillment(of: [nextStarted], timeout: 1)
        try generator.complete(index: 1, result: .success("再開します。"))
        await fulfillment(of: [nextCompleted], timeout: 1)
        XCTAssertEqual(results, [nil])
    }

    func testCancelSuppressesLateCompletionWithoutCancellingTheNextRequest() async throws {
        let generator = ControlledPunctuationGenerator()
        defer { generator.cancelPending() }
        let worker = HaasPunctuationWorker(generator: generator, timeout: .seconds(2))
        let oldID = UUID()
        let started = expectation(description: "Old request started")
        let exited = expectation(description: "Old native request exits")
        generator.onStarted = { _ in started.fulfill() }
        generator.onExited = { _ in exited.fulfill() }
        var oldResults: [String?] = []
        XCTAssertTrue(worker.submit("取り消します", requestID: oldID) { oldResults.append($0) })
        await fulfillment(of: [started], timeout: 1)
        worker.cancel(requestID: oldID)
        XCTAssertTrue(oldResults.isEmpty)
        XCTAssertFalse(worker.submit("まだ重ねません", requestID: UUID()) { _ in
            XCTFail("Cancellation must retain the occupied native slot")
        })

        try generator.complete(index: 0, result: .success("取り消します。"))
        await fulfillment(of: [exited], timeout: 1)
        XCTAssertTrue(oldResults.isEmpty)
        XCTAssertEqual(generator.cancelledAtExit[0], true)

        generator.onExited = nil
        let nextStarted = expectation(description: "New request started")
        let nextCompleted = expectation(description: "New completion survives stale cancellation")
        generator.onStarted = { _ in nextStarted.fulfill() }
        var nextResults: [String?] = []
        XCTAssertTrue(worker.submit("今回です", requestID: UUID()) {
            nextResults.append($0)
            nextCompleted.fulfill()
        })
        await fulfillment(of: [nextStarted], timeout: 1)
        worker.cancel(requestID: oldID)
        try generator.complete(index: 1, result: .success("今回です。"))
        await fulfillment(of: [nextCompleted], timeout: 1)
        XCTAssertEqual(nextResults, ["今回です。"])
        XCTAssertEqual(generator.cancelledAtExit[1], false)
        XCTAssertTrue(oldResults.isEmpty)
    }

    func testUnavailableAndAlreadyExpiredRequestsAreDeclinedWithoutGeneration() async {
        let unavailable = ControlledPunctuationGenerator()
        unavailable.unavailableReason = "モデルを利用できません"
        let available = ControlledPunctuationGenerator()
        let cases: [(name: String, generator: ControlledPunctuationGenerator?, receivedAt: ContinuousClock.Instant)] = [
            ("no generator", nil, .now),
            ("unavailable generator", unavailable, .now),
            ("expired before admission", available, ContinuousClock.now - .seconds(2)),
        ]
        for item in cases {
            let worker = HaasPunctuationWorker(generator: item.generator, timeout: .seconds(1))
            var completions = 0
            XCTAssertFalse(worker.submit("原文を保持します", requestID: UUID(), receivedAt: item.receivedAt) { _ in
                completions += 1
            }, item.name)
            await Task.yield()
            XCTAssertEqual(completions, 0, item.name)
            XCTAssertTrue(item.generator?.requests.isEmpty ?? true, item.name)
        }
    }

    func testInvalidOutputAndGenerationErrorRequestFallback() async throws {
        let cases: [(name: String, result: Result<String, Error>)] = [
            ("changed name", .success("JIHAN は3台です。")),
            ("generation failed", .failure(InjectedGenerationError.failed)),
        ]
        for item in cases {
            let generator = ControlledPunctuationGenerator()
            defer { generator.cancelPending() }
            let worker = HaasPunctuationWorker(generator: generator, timeout: .seconds(2))
            let started = expectation(description: item.name + " started")
            let completed = expectation(description: item.name + " fallback")
            generator.onStarted = { _ in started.fulfill() }
            var results: [String?] = []
            XCTAssertTrue(worker.submit("JiHAN は3台です", requestID: UUID()) {
                results.append($0)
                completed.fulfill()
            })
            await fulfillment(of: [started], timeout: 1)
            try generator.complete(index: 0, result: item.result)
            await fulfillment(of: [completed], timeout: 1)
            XCTAssertEqual(results, [nil], item.name)
        }
    }

    func testActorSchedulingDelayCountsAgainstTheOriginalDeadline() async {
        let generator = ControlledPunctuationGenerator()
        defer { generator.cancelPending() }
        let worker = HaasPunctuationWorker(generator: generator, timeout: .milliseconds(40))
        let completed = expectation(description: "Expired queued request falls back")
        var results: [String?] = []
        XCTAssertTrue(worker.submit("遅れて届きます", requestID: UUID()) {
            results.append($0)
            completed.fulfill()
        })
        occupyCurrentActor(for: 0.08)
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertTrue(generator.requests.isEmpty, "An expired queued request must not start the model")
        XCTAssertEqual(results, [nil])
    }

    func testProofreadingValidatorAcceptsCorrectionsAndPassesProtectedTerms() async throws {
        let generator = ControlledPunctuationGenerator()
        defer { generator.cancelPending() }
        var seenTerms: [String] = []
        let worker = HaasPunctuationWorker(generator: generator, timeout: .seconds(2)) { candidate, original, terms in
            seenTerms = terms
            return HaasProofreadValidator.validatedCandidate(candidate, preserving: original, protectedTerms: terms)
        }
        let started = expectation(description: "started")
        let done = expectation(description: "done")
        generator.onStarted = { _ in started.fulfill() }
        var result: String??
        XCTAssertTrue(worker.submit("巽さんの端末ないで", requestID: UUID(), protectedTerms: ["巽"]) {
            result = $0
            done.fulfill()
        })
        await fulfillment(of: [started], timeout: 1)
        try generator.complete(index: 0, result: .success("巽さんの端末内で"))
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(result, .some("巽さんの端末内で"))
        XCTAssertEqual(seenTerms, ["巽"])
    }

    func testDefaultValidatorStillRejectsWordChangesForPunctuationOnlyMode() async throws {
        let generator = ControlledPunctuationGenerator()
        defer { generator.cancelPending() }
        let worker = HaasPunctuationWorker(generator: generator, timeout: .seconds(2))
        let started = expectation(description: "started")
        let done = expectation(description: "done")
        generator.onStarted = { _ in started.fulfill() }
        var result: String??
        XCTAssertTrue(worker.submit("端末ないで", requestID: UUID()) {
            result = $0
            done.fulfill()
        })
        await fulfillment(of: [started], timeout: 1)
        try generator.complete(index: 0, result: .success("端末内で"))
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(result, .some(nil))
    }

    private func occupyCurrentActor(for interval: TimeInterval) {
        Thread.sleep(forTimeInterval: interval)
    }
}

private enum InjectedGenerationError: Error { case failed }

@MainActor
final class ControlledPunctuationGenerator: HaasPunctuationGenerating {
    var unavailableReason: String?
    private(set) var requests: [String] = []
    private(set) var cancelledAtExit: [Int: Bool] = [:]
    var onStarted: ((Int) -> Void)?
    var onExited: ((Int) -> Void)?
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]

    func prewarm() {}

    func generate(_ text: String) async throws -> String {
        let index = requests.count
        requests.append(text)
        defer {
            cancelledAtExit[index] = Task.isCancelled
            onExited?(index)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            onStarted?(index)
        }
    }

    func complete(index: Int, result: Result<String, Error>) throws {
        let continuation = try XCTUnwrap(pending.removeValue(forKey: index))
        continuation.resume(with: result)
    }

    func cancelPending() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}
