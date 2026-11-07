import Foundation
import SwiftData
import XCTest
@testable import VoiceInk

@MainActor
final class HaasUsageRecorderTests: XCTestCase {
    private struct SaveFailure: Error {}

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Transcription.self, SessionMetric.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @discardableResult
    private func insert(
        _ text: String, status: TranscriptionStatus = .completed, duration: TimeInterval = 3,
        into context: ModelContext
    ) -> Transcription {
        let row = Transcription(text: text, duration: duration, transcriptionStatus: status)
        context.insert(row)
        return row
    }

    private func metrics(_ container: ModelContainer) throws -> [SessionMetric] {
        try ModelContext(container).fetch(FetchDescriptor<SessionMetric>())
    }

    func testSyncBackfillsOnlyCompletedRowsWithText() throws {
        let container = try makeContainer()
        let history = container.mainContext
        insert("こんにちは", into: history)
        insert(" ", into: history)
        insert("あいう", status: .canceled, into: history)
        insert("かきく", status: .failed, into: history)
        try history.save()

        let recorder = HaasUsageRecorder(container: container)
        recorder.sync(from: history)

        XCTAssertEqual(recorder.samples.count, 1)
        XCTAssertEqual(recorder.samples.first?.characters, 5)
    }

    func testSyncIsIdempotent() throws {
        let container = try makeContainer()
        let history = container.mainContext
        insert("こんにちは", into: history)
        try history.save()

        let recorder = HaasUsageRecorder(container: container)
        recorder.sync(from: history)
        recorder.sync(from: history)

        XCTAssertEqual(try metrics(container).count, 1)
        XCTAssertEqual(recorder.samples.count, 1)
    }

    func testStatisticsSurviveHistoryDeletion() throws {
        let container = try makeContainer()
        let history = container.mainContext
        let row = insert("こんにちは", into: history)
        try history.save()

        let recorder = HaasUsageRecorder(container: container)
        recorder.sync(from: history)
        history.delete(row)
        try history.save()
        recorder.sync(from: history)

        XCTAssertEqual(recorder.samples.count, 1)
    }

    func testSampleCopiesTimestampAndDuration() throws {
        let container = try makeContainer()
        let history = container.mainContext
        let row = insert("こんにちは", duration: 12.5, into: history)
        try history.save()

        let recorder = HaasUsageRecorder(container: container)
        recorder.sync(from: history)

        XCTAssertEqual(recorder.samples.first?.timestamp, row.timestamp)
        XCTAssertEqual(recorder.samples.first?.duration, row.duration)
    }

    func testSaveFailureKeepsHistoryCleanAndRetriesLater() throws {
        let container = try makeContainer()
        let history = container.mainContext
        let row = insert("こんにちは", into: history)
        try history.save()

        var calls = 0
        let recorder = HaasUsageRecorder(container: container) { context in
            calls += 1
            if calls == 1 { throw SaveFailure() }
            try context.save()
        }
        recorder.sync(from: history)

        XCTAssertFalse(history.hasChanges)
        XCTAssertEqual(recorder.samples.count, 1)
        XCTAssertEqual(try metrics(container).count, 0)

        history.delete(row)
        try history.save()
        recorder.sync(from: history)

        XCTAssertEqual(try metrics(container).count, 1)
        XCTAssertEqual(recorder.samples.count, 1)
    }

    func testSyncDoesNotTouchUnsavedHistoryChanges() throws {
        let container = try makeContainer()
        let history = container.mainContext
        insert("こんにちは", into: history)
        XCTAssertTrue(history.hasChanges)

        let recorder = HaasUsageRecorder(container: container)
        recorder.sync(from: history)

        XCTAssertTrue(history.hasChanges)
        XCTAssertEqual(recorder.samples.count, 0)

        try history.save()
        recorder.sync(from: history)
        XCTAssertEqual(recorder.samples.count, 1)
    }

    func testLegacyMetricsAreIgnoredAndKept() throws {
        let container = try makeContainer()
        let history = container.mainContext
        let row = insert("こんにちは", into: history)
        try history.save()
        history.insert(SessionMetric(
            transcriptionId: row.id, source: "recorder", wordCount: 7, audioDuration: 1,
            transcriptionModelName: nil, transcriptionDuration: nil, speedFactor: nil,
            modeName: nil, aiEnhancementModelName: nil, enhancementDuration: nil
        ))
        try history.save()

        let recorder = HaasUsageRecorder(container: container)
        recorder.sync(from: history)

        XCTAssertEqual(recorder.samples.map(\.characters), [5])
        let legacy = try metrics(container).filter { $0.source == "recorder" }
        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(legacy.first?.wordCount, 7)
    }

    func testNilSourceLegacyMetricIsIgnoredAndKept() throws {
        let container = try makeContainer()
        let history = container.mainContext
        let row = insert("こんにちは", into: history)
        try history.save()
        history.insert(SessionMetric(
            transcriptionId: row.id, source: nil, wordCount: 7, audioDuration: 1,
            transcriptionModelName: nil, transcriptionDuration: nil, speedFactor: nil,
            modeName: nil, aiEnhancementModelName: nil, enhancementDuration: nil
        ))
        try history.save()

        let recorder = HaasUsageRecorder(container: container)
        recorder.sync(from: history)

        // 文字数は本文から数え、source が nil の旧記録は参照せず、削除もしない
        XCTAssertEqual(recorder.samples.map(\.characters), [5])
        let legacy = try metrics(container).filter { $0.source == nil }
        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(legacy.first?.wordCount, 7)
    }

    func testStatisticsPersistAcrossReopenWithRealConfigurations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaasUsageRecorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let persistence = try HaasPersistence(directory: directory)
            let row = insert("こんにちは", into: persistence.mainContext)
            try persistence.mainContext.save()
            let recorder = HaasUsageRecorder(container: persistence.container)
            recorder.sync(from: persistence.mainContext)
            XCTAssertEqual(recorder.samples.count, 1)
            persistence.mainContext.delete(row)
            try persistence.mainContext.save()
        }

        let reopened = try HaasPersistence(directory: directory)
        let recorder = HaasUsageRecorder(container: reopened.container)
        recorder.sync(from: reopened.mainContext)
        XCTAssertEqual(recorder.samples.count, 1)
    }
}
