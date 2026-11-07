import AVFoundation
import SwiftData
import XCTest
@testable import VoiceInk

@MainActor
final class HaasRecordingLifecycleTests: XCTestCase {
    func testCancellationWaitsForPendingPreparationBeforeAcceptingAnotherStart() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanUp() }
        let gate = AsyncGate()
        defer { gate.open() }
        let prepared = expectation(description: "Session preparation is pending")
        gate.onEntered = { prepared.fulfill() }
        fixture.configureSession = { $0.prepareGate = gate }
        let acceptedID = try XCTUnwrap(fixture.engine.startHeldRecording())
        await fulfillment(of: [prepared], timeout: 2)
        XCTAssertEqual(fixture.engine.activeRecordingStartID, acceptedID)

        let cancel = Task { await fixture.engine.cancelRecording() }
        await waitUntil { fixture.engine.recordingState == .busy }
        if fixture.engine.recordingState != .idle {
            let refusedStart = fixture.engine.startHeldRecording()
            XCTAssertNil(refusedStart)
        } else {
            XCTFail("A new recording became available before cleanup finished")
        }
        XCTAssertEqual(fixture.audio.startCount, 0)
        gate.open()
        await cancel.value
        XCTAssertEqual(fixture.engine.recordingState, .idle)
        XCTAssertNil(fixture.engine.activeRecordingStartID)
        XCTAssertTrue(try fixture.rows().isEmpty)
    }

    func testFailedHardwareStartKeepsNewRecordingBlockedUntilHardwareCleanup() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanUp() }
        let gate = AsyncGate()
        defer { gate.open() }
        let stopped = expectation(description: "Failed hardware is being cleaned up")
        gate.onEntered = { stopped.fulfill() }
        fixture.audio.startError = URLError(.cannotOpenFile)
        fixture.audio.stopGate = gate
        let acceptedID = try XCTUnwrap(fixture.engine.startHeldRecording())
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(fixture.engine.activeRecordingStartID, acceptedID)
        XCTAssertEqual(fixture.engine.recordingState, .busy)
        if fixture.engine.recordingState != .idle {
            let refusedStart = fixture.engine.startHeldRecording()
            XCTAssertNil(refusedStart)
        } else {
            XCTFail("A new recording became available before cleanup finished")
        }
        XCTAssertEqual(fixture.audio.startCount, 1)
        gate.open()
        await waitUntil { fixture.engine.recordingState == .idle }
        XCTAssertNil(fixture.engine.activeRecordingStartID)
        XCTAssertNotNil(fixture.engine.errorMessage)
        XCTAssertEqual(fixture.audio.stopCount, 1)
        XCTAssertEqual(try fixture.rows().first?.transcriptionStatus, TranscriptionStatus.failed.rawValue)
    }

    func testCancelDuringHardwareStopKeepsHistoryAudioAndRecoveryLinked() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanUp() }
        let id = try await beginRecording(fixture)
        let session = try XCTUnwrap(fixture.sessions.last)
        session.emitCommitted("保存する途中の文章")
        let audioURL = try XCTUnwrap(fixture.engine.activeAudioURL)
        let gate = AsyncGate()
        defer { gate.open() }
        let stopped = expectation(description: "Hardware stop is pending")
        gate.onEntered = { stopped.fulfill() }
        fixture.audio.stopGate = gate
        fixture.engine.finishHeldShortcutRecording(recordingID: id)
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(fixture.engine.recordingState, .transcribing)
        XCTAssertEqual(session.finishCount, 0, "ASR drain must follow the hardware stop")

        let cancel = Task { await fixture.engine.cancelRecording() }
        await waitUntil { fixture.engine.recordingState == .busy }
        if fixture.engine.recordingState != .idle {
            let refusedStart = fixture.engine.startHeldRecording()
            XCTAssertNil(refusedStart)
        } else {
            XCTFail("A new recording became available before cleanup finished")
        }
        gate.open()
        await cancel.value
        XCTAssertEqual(fixture.engine.recordingState, .idle)
        let rows = try fixture.rows()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.text, "保存する途中の文章")
        XCTAssertEqual(row.audioFileURL, audioURL.absoluteString)
        XCTAssertEqual(row.transcriptionStatus, TranscriptionStatus.canceled.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        let saved = try fixture.savedRecovery()
        let recovery = try XCTUnwrap(([saved.active].compactMap { $0 } + saved.archives).first { $0.id == session.sessionID })
        XCTAssertEqual(recovery.transcriptionID, row.id)
        XCTAssertEqual(recovery.ledger.pendingText, row.text)
        XCTAssertEqual(session.finishCount, 1)
        XCTAssertEqual(fixture.audio.stopCount, 1)
    }

    func testOldCallbacksAndReleaseDoNotChangeNextRecordingAndCurrentFailureStopsIt() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanUp() }
        let oldID = try await beginRecording(fixture)
        let old = try XCTUnwrap(fixture.sessions.last)
        old.emitCommitted("前の文章")
        fixture.engine.finishHeldShortcutRecording(recordingID: oldID)
        await waitUntil { fixture.engine.recordingState == .idle }
        let newID = try await beginRecording(fixture)
        let current = try XCTUnwrap(fixture.sessions.last)
        current.emitCommitted("今回の文章")
        current.options.onPartialTranscript("今回の途中表示")

        old.options.onPartialTranscript("遅れてきた古い表示")
        old.options.onFailure(URLError(.timedOut))
        fixture.engine.finishHeldShortcutRecording(recordingID: oldID)
        XCTAssertEqual(fixture.engine.activeRecordingStartID, newID)
        XCTAssertEqual(fixture.engine.recordingState, .recording)
        XCTAssertEqual(fixture.engine.partialTranscript, "今回の途中表示")

        let gate = AsyncGate()
        defer { gate.open() }
        let stopped = expectation(description: "Current recognition failure stops hardware")
        gate.onEntered = { stopped.fulfill() }
        fixture.audio.stopGate = gate
        current.emitFailure(URLError(.networkConnectionLost))
        await fulfillment(of: [stopped], timeout: 2)
        if fixture.engine.recordingState != .idle {
            let refusedStart = fixture.engine.startHeldRecording()
            XCTAssertNil(refusedStart)
        } else {
            XCTFail("A new recording became available before cleanup finished")
        }
        XCTAssertEqual(current.finishCount, 0)
        gate.open()
        await waitUntil { fixture.engine.recordingState == .idle }
        let rows = try fixture.rows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.text == "前の文章" }?.transcriptionStatus, TranscriptionStatus.completed.rawValue)
        XCTAssertEqual(rows.first { $0.text == "今回の文章" }?.transcriptionStatus, TranscriptionStatus.failed.rawValue)
    }

    func testPunctuationModeIsCapturedBeforePermissionWaitAndPartialIsShownDuringStart() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanUp() }
        let permission = AsyncGate()
        defer { permission.open() }
        let permissionPending = expectation(description: "Permission request is pending")
        permission.onEntered = { permissionPending.fulfill() }
        fixture.audio.permissionGate = permission
        UserDefaults.standard.set(HaasPunctuationMode.fast.rawValue, forKey: HaasPunctuationMode.settingsKey)
        let id = try XCTUnwrap(fixture.engine.startHeldRecording())
        await fulfillment(of: [permissionPending], timeout: 2)
        UserDefaults.standard.set(HaasPunctuationMode.natural.rawValue, forKey: HaasPunctuationMode.settingsKey)
        fixture.audio.onStart = { fixture.sessions.last?.options.onPartialTranscript("最初の途中表示") }
        permission.open()
        await waitUntil { fixture.engine.recordingState == .recording }
        XCTAssertEqual(fixture.sessions.last?.options.punctuationMode, .fast)
        XCTAssertEqual(fixture.engine.partialTranscript, "最初の途中表示")
        fixture.engine.finishHeldShortcutRecording(recordingID: id)
        await waitUntil { fixture.engine.recordingState == .idle }

        fixture.audio.permissionGate = nil
        _ = try await beginRecording(fixture)
        XCTAssertEqual(fixture.sessions.last?.options.punctuationMode, .natural)
        await fixture.engine.cancelRecording()

        UserDefaults.standard.set("proofread", forKey: HaasPunctuationMode.settingsKey)
        _ = try await beginRecording(fixture)
        XCTAssertEqual(fixture.sessions.last?.options.punctuationMode, .proofread)
        await fixture.engine.cancelRecording()
    }

    func testTerminationRefusesToDiscardUnsavedRecovery() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanUp() }
        _ = try await beginRecording(fixture)
        let session = try XCTUnwrap(fixture.sessions.last)
        try FileManager.default.moveItem(
            at: fixture.recoveryURL.deletingLastPathComponent(),
            to: fixture.root.appendingPathComponent("retained-recovery")
        )
        try Data("not a directory".utf8).write(to: fixture.recoveryURL.deletingLastPathComponent())
        session.emitCommitted("保存できなくても残す文章")
        XCTAssertTrue(fixture.delivery.hasUnsavedRecovery)
        let canTerminate = await fixture.engine.prepareForTermination()
        XCTAssertFalse(canTerminate)
        XCTAssertEqual(fixture.delivery.pendingText, "保存できなくても残す文章")
        XCTAssertEqual(try fixture.rows().first?.text, "保存できなくても残す文章")
        XCTAssertEqual(fixture.engine.recordingState, .idle)
    }

    func testHeldShortcutReleaseDuringPreparationDoesNotStartHardware() async throws {
        let scenarios: [(name: String, mode: RecordingShortcutManager.Mode, heldFor: TimeInterval, shouldStart: Bool)] = [
            ("push to talk release", .pushToTalk, 0.2, false),
            ("hybrid long release", .hybrid, 0.8, false),
            ("hybrid short release", .hybrid, 0.1, true),
        ]
        for scenario in scenarios {
            let fixture = try EngineFixture()
            defer { fixture.cleanUp() }
            let gate = AsyncGate()
            defer { gate.open() }
            let preparing = expectation(description: scenario.name + " reaches preparation")
            gate.onEntered = { preparing.fulfill() }
            fixture.configureSession = { $0.prepareGate = gate }
            let engine = fixture.engine
            let handler = fixture.makeShortcutHandler()
            let down = Task {
                await handler.handleShortcutDown(action: .primaryRecording, eventTime: 100, mode: scenario.mode)
            }
            await fulfillment(of: [preparing], timeout: 2)
            XCTAssertEqual(engine.recordingState, .starting, scenario.name)
            await handler.handleShortcutUp(action: .primaryRecording, eventTime: 100 + scenario.heldFor, mode: scenario.mode)
            gate.open()
            await down.value
            let expectedState: RecordingState = scenario.shouldStart ? .recording : .idle
            await waitUntil { engine.recordingState == expectedState }
            XCTAssertEqual(fixture.audio.startCount, scenario.shouldStart ? 1 : 0, scenario.name)
            await engine.cancelRecording()
        }
    }

    func testCancelInvalidatesPendingHardwareStartBeforeWaitingForCleanup() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanUp() }
        let startGate = AsyncGate(), stopGate = AsyncGate()
        defer { startGate.open(); stopGate.open() }
        let starting = expectation(description: "Hardware start is pending")
        startGate.onEntered = { starting.fulfill() }
        fixture.audio.startGate = startGate
        fixture.audio.stopGate = stopGate
        let acceptedID = try XCTUnwrap(fixture.engine.startHeldRecording())
        await fulfillment(of: [starting], timeout: 2)
        XCTAssertEqual(fixture.engine.activeRecordingStartID, acceptedID)
        let cancel = Task { await fixture.engine.cancelRecording() }
        await waitUntil { fixture.engine.recordingState == .busy }
        await waitUntil { fixture.audio.stopCount > 0 }
        XCTAssertTrue(fixture.audio.pendingStartCancelled)
        XCTAssertNotNil(fixture.engine.activeRecordingStartID)
        startGate.open()
        stopGate.open()
        await cancel.value
        XCTAssertEqual(fixture.audio.successfulStarts, 0)
        XCTAssertEqual(fixture.audio.stopCount, 1)
        XCTAssertEqual(fixture.engine.recordingState, .idle)
    }

    func testMissedPTTReleaseAndNextPressCanStopTheOwnedRecording() async throws {
        for monitorReportedRelease in [true, false] {
            let fixture = try EngineFixture()
            defer { fixture.cleanUp() }
            let engine = fixture.engine
            let handler = fixture.makeShortcutHandler()
            await handler.handleShortcutDown(action: .primaryRecording, eventTime: 200, mode: .pushToTalk)
            await waitUntil { engine.recordingState == .recording }
            XCTAssertNotNil(engine.activeRecordingStartID)
            if monitorReportedRelease { handler.recoverMissedRelease(for: .primaryRecording) }
            await handler.handleShortcutDown(action: .primaryRecording, eventTime: 202, mode: .pushToTalk)
            await handler.handleShortcutUp(action: .primaryRecording, eventTime: 203, mode: .pushToTalk)
            await waitUntil { engine.recordingState == .idle }
            XCTAssertNil(engine.activeRecordingStartID,
                         monitorReportedRelease ? "monitor recovery must retain stop ownership" : "a fresh press must recover missed release")
            await engine.cancelRecording()
        }
    }

    func testAudioWriteFailureKeepsPartialHistoryAndIgnoresStaleFailureCallback() async throws {
        for failsDuringStop in [false, true] {
            let fixture = try EngineFixture()
            defer { fixture.cleanUp() }
            let engine = fixture.engine
            let id = try await beginRecording(fixture)
            let session = try XCTUnwrap(fixture.sessions.last)
            session.emitCommitted("保存できた認識済みの本文")
            let audioURL = try XCTUnwrap(engine.activeAudioURL)
            let failureCallback = fixture.audio.onRecordingFailure
            XCTAssertNotNil(failureCallback)
            let failure = NSError(domain: "SyntheticAudioWriteFailure", code: -34)
            if failsDuringStop {
                fixture.audio.failureAtStop = failure
                engine.finishHeldShortcutRecording(recordingID: id)
            } else {
                fixture.audio.onRecordingFailure?(failure)
            }
            await waitUntil { engine.recordingState == .idle }
            if engine.recordingState == .recording {
                engine.finishHeldShortcutRecording(recordingID: id)
                await waitUntil { engine.recordingState == .idle }
            }
            let row = try XCTUnwrap(fixture.rows().first)
            XCTAssertEqual(row.transcriptionStatus, TranscriptionStatus.failed.rawValue,
                           failsDuringStop ? "drain failure must reach history before stop returns" : "write failure must stop recording")
            XCTAssertEqual(row.text, "保存できた認識済みの本文")
            XCTAssertEqual(row.audioFileURL, audioURL.absoluteString)
            XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
            XCTAssertNotNil(engine.errorMessage)

            fixture.audio.failureAtStop = nil
            let nextID = try await beginRecording(fixture)
            fixture.sessions.last?.options.onPartialTranscript("次の録音の途中表示")
            failureCallback?(failure)
            await Task.yield()
            XCTAssertEqual(engine.activeRecordingStartID, nextID)
            XCTAssertEqual(engine.recordingState, .recording)
            XCTAssertEqual(engine.partialTranscript, "次の録音の途中表示")
            await engine.cancelRecording()
        }
    }

    func testTerminationWaitsForAudioRestorationAndRejectsNewStartsWhileWaiting() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanUp() }
        let engine = fixture.engine
        let id = try await beginRecording(fixture)
        engine.finishHeldShortcutRecording(recordingID: id)
        await waitUntil { engine.recordingState == .idle }
        let restoration = AsyncGate()
        defer { restoration.open() }
        fixture.audio.restorationGate = restoration
        var returned = false
        let termination = Task {
            let result = await engine.prepareForTermination()
            returned = true
            return result
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !returned && fixture.audio.restorationWaitCount == 0 && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(returned, "Termination must wait for owned audio restoration even after recording becomes idle")
        let refused = engine.startHeldRecording()
        XCTAssertNil(refused, "A pending termination must not start a new recording")
        if refused != nil { await engine.cancelRecording() }
        restoration.open()
        let mayTerminate = await termination.value
        XCTAssertTrue(mayTerminate)
        let next = engine.startHeldRecording()
        XCTAssertNotNil(next, "The temporary termination guard is released after the operation returns")
        await engine.cancelRecording()
    }

    func testCompletedRecordingIsRecordedInUsageStatistics() async throws {
        let fixture = try EngineFixture(recordsUsage: true)
        defer { fixture.cleanUp() }
        try await completeRecording(fixture, text: "資料を送ります")
        let recorder = try XCTUnwrap(fixture.usageRecorder)
        XCTAssertEqual(recorder.samples.count, 1)
        XCTAssertEqual(recorder.samples.first?.characters, 7)
    }

    func testUsageStatisticsSurviveImmediateHistoryCleanup() async throws {
        let fixture = try EngineFixture(recordsUsage: true)
        defer { fixture.cleanUp() }
        UserDefaults.standard.set(true, forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled)
        UserDefaults.standard.set(0, forKey: CleanupSettingsKeys.transcriptionRetentionMinutes)
        try await completeRecording(fixture, text: "一回目の文章")
        try await completeRecording(fixture, text: "二回目の文章")
        XCTAssertTrue(try fixture.rows().isEmpty)
        XCTAssertEqual(try XCTUnwrap(fixture.usageRecorder).samples.count, 2)
    }

    private func completeRecording(_ fixture: EngineFixture, text: String) async throws {
        let id = try await beginRecording(fixture)
        try XCTUnwrap(fixture.sessions.last).emitCommitted(text)
        fixture.engine.finishHeldShortcutRecording(recordingID: id)
        await waitUntil { fixture.engine.recordingState == .idle }
    }

    private func beginRecording(_ fixture: EngineFixture) async throws -> UUID {
        let id = try XCTUnwrap(fixture.engine.startHeldRecording())
        await waitUntil { fixture.engine.recordingState == .recording }
        return id
    }

    func testPasteLastTranscriptionAlwaysInvalidatesInputWatch() async throws {
        let fixture = try EngineFixture()
        defer { fixture.cleanUp() }
        XCTAssertEqual(fixture.watcher.invalidateCount, 0)
        // ショートカットを通さずに呼んでも、この貼り付けの後に直前の入力を置き換えさせない
        fixture.engine.pasteLastTranscription()
        XCTAssertEqual(fixture.watcher.invalidateCount, 1)
        await waitUntil { fixture.engine.errorMessage != nil }
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class EngineFixture {
    let root: URL
    let recoveryURL: URL
    let defaults: UserDefaults
    let suite: String
    let container: ModelContainer
    let audio = ControlledAudioRecorder()
    let watcher = LifecycleFakeInputWatcher()
    let delivery: HaasInputDelivery
    var sessions: [ControlledRecordingSession] = []
    var configureSession: ((ControlledRecordingSession) -> Void)?
    let usageRecorder: HaasUsageRecorder?
    private let oldPreferences: [(String, Any?)]

    lazy var engine = HaasEngine(
        modelContext: container.mainContext,
        recorder: audio,
        sessionFactory: { [unowned self] options in
            let session = ControlledRecordingSession(options: options)
            configureSession?(session)
            sessions.append(session)
            return session
        },
        inputDelivery: delivery,
        recordingsDirectory: root.appendingPathComponent("Recordings", isDirectory: true),
        usageRecorder: usageRecorder
    )

    init(recordsUsage: Bool = false) throws {
        guard Bundle.main.bundleIdentifier == "com.tatsumi.VoiceInkHaas.TestsHost" else {
            throw CocoaError(.fileReadNoPermission)
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HaasEngineTests-\(UUID().uuidString)")
        recoveryURL = root.appendingPathComponent("recovery/state.json")
        suite = "HaasEngineTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let schema = Schema(recordsUsage
            ? [Transcription.self, WordReplacement.self, SessionMetric.self]
            : [Transcription.self, WordReplacement.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: configuration)
        usageRecorder = recordsUsage ? HaasUsageRecorder(container: container) : nil
        delivery = HaasInputDelivery(
            store: HaasRecoveryStore(fileURL: recoveryURL, legacyDefaults: defaults), textPaster: NoInputPaster(),
            inputMonitor: watcher
        )
        let persistent = UserDefaults.standard.persistentDomain(forName: "com.tatsumi.VoiceInkHaas.TestsHost") ?? [:]
        let keys = [HaasPunctuationMode.settingsKey, CleanupSettingsKeys.isTranscriptionCleanupEnabled,
                    CleanupSettingsKeys.isAudioCleanupEnabled,
                    CleanupSettingsKeys.transcriptionRetentionMinutes]
        oldPreferences = keys.map { ($0, persistent[$0]) }
        UserDefaults.standard.set(false, forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled)
        UserDefaults.standard.set(false, forKey: CleanupSettingsKeys.isAudioCleanupEnabled)
    }

    func makeShortcutHandler() -> RecordingShortcutModeHandler {
        let engine = self.engine
        return RecordingShortcutModeHandler(
            canHandleShortcutAction: { engine.recordingState != .busy && engine.recordingState != .transcribing },
            isRecorderVisible: { engine.recordingState != .idle },
            recordingState: { engine.recordingState },
            activeRecordingStartID: { engine.activeRecordingStartID },
            isShortcutHeld: { _ in false },
            startHeldRecording: { engine.startHeldRecording() },
            finishHeldRecording: { engine.finishHeldShortcutRecording(recordingID: $0) },
            toggleRecording: { await engine.toggleRecording() },
            cancelRecording: { await engine.cancelRecording(recordingID: $0) }
        )
    }

    func rows() throws -> [Transcription] { try container.mainContext.fetch(FetchDescriptor<Transcription>()) }
    func savedRecovery() throws -> HaasRecoveryState {
        try JSONDecoder().decode(HaasRecoveryState.self, from: Data(contentsOf: recoveryURL))
    }
    func cleanUp() {
        for (key, value) in oldPreferences {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class AsyncGate {
    var onEntered: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        onEntered?()
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class ControlledAudioRecorder: HaasAudioRecording {
    var onAudioChunk: ((Data) -> Void)?
    var onRecordingFailure: ((Error) -> Void)?
    var failureAtStop: Error?
    var restorationGate: AsyncGate?
    private(set) var restorationWaitCount = 0
    var permissionGate: AsyncGate?
    var startGate: AsyncGate?
    var stopGate: AsyncGate?
    var startError: Error?
    var onStart: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var pendingStartCancelled = false
    private(set) var successfulStarts = 0

    func cancelPendingStart() { pendingStartCancelled = true }

    func requestMicrophoneAccess() async -> Bool {
        await permissionGate?.wait()
        return true
    }
    func startRecording(toOutputFile url: URL) async throws {
        startCount += 1
        pendingStartCancelled = false
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: HaasPCMConverter.outputSampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
        buffer.frameLength = 2_400
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<2_400 { samples[index] = 0 }
        try file.write(from: buffer)
        onStart?()
        await startGate?.wait()
        if pendingStartCancelled { throw CancellationError() }
        if let startError { throw startError }
        successfulStarts += 1
    }
    func stopRecording(expectedGeneration: UUID?) async {
        stopCount += 1
        await stopGate?.wait()
        if let failureAtStop { onRecordingFailure?(failureAtStop) }
    }
    func waitForAudioRestoration() async {
        restorationWaitCount += 1
        await restorationGate?.wait()
    }
    func audioMeterSnapshot() -> AudioMeter { AudioMeter(averagePower: 0, peakPower: 0) }
}

@MainActor
private final class ControlledRecordingSession: HaasRecordingSession {
    let sessionID = UUID()
    let options: HaasSessionOptions
    var prepareGate: AsyncGate?
    private(set) var recognizedText = ""
    private(set) var finishCount = 0
    private var cancelled = false
    private var finished = false
    private var failure: Error?

    init(options: HaasSessionOptions) { self.options = options }
    func prepare() async throws -> ((Data) -> Void)? {
        try await options.delivery.begin(sessionID: sessionID, target: nil)
        await prepareGate?.wait()
        if cancelled { throw CancellationError() }
        return { _ in }
    }
    func finish() async throws -> String {
        finishCount += 1
        await options.delivery.finish(sessionID: sessionID)
        finished = true
        if let failure { throw failure }
        if cancelled { throw CancellationError() }
        return recognizedText
    }
    func cancel() {
        cancelled = true
        if !finished { options.delivery.cancel(sessionID: sessionID, message: "合成セッションを取消") }
    }
    func attachTranscription(_ id: UUID) {
        options.delivery.attachTranscription(sessionID: sessionID, transcriptionID: id)
    }
    func emitCommitted(_ text: String) {
        recognizedText += text
        options.delivery.accept(sessionID: sessionID, itemID: UUID().uuidString, text: text)
    }
    func emitFailure(_ error: Error) {
        failure = error
        options.delivery.pause(sessionID: sessionID, message: "合成した認識障害")
        options.onFailure(error)
    }
}

@MainActor
private struct NoInputPaster: HaasTextPasting {
    func paste(_ text: String, shouldPaste: @escaping () -> Bool) async -> CursorPaster.PasteOutcome {
        .init(result: .commandNotPosted)
    }
    func copy(_ text: String) -> Bool { false }
}

@MainActor
private final class LifecycleFakeInputWatcher: HaasInputWatching {
    private(set) var invalidateCount = 0
    func startWatching() -> UUID { UUID() }
    func isClean(for token: UUID) -> Bool { false }
    func invalidate() { invalidateCount += 1 }
}
