import AppKit
import AVFoundation
import Combine
import Foundation
import os
import SwiftData

enum RecordingState: String {
    case idle, starting, recording, transcribing, busy

    var displayName: String {
        switch self {
        case .idle: return "待機中"
        case .starting: return "録音を準備しています"
        case .recording: return "録音中"
        case .transcribing: return "最後の音声を認識しています"
        case .busy: return "録音を終了しています"
        }
    }
}

@MainActor
protocol HaasAudioRecording: AnyObject {
    var onAudioChunk: ((Data) -> Void)? { get set }
    var onRecordingFailure: ((Error) -> Void)? { get set }
    func requestMicrophoneAccess() async -> Bool
    func cancelPendingStart()
    func startRecording(toOutputFile url: URL) async throws
    func stopRecording(expectedGeneration: UUID?) async
    func waitForAudioRestoration() async
    func audioMeterSnapshot() -> AudioMeter
}

extension Recorder: HaasAudioRecording {
    func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

@MainActor
protocol HaasRecordingSession: AnyObject {
    var sessionID: UUID { get }
    var recognizedText: String { get }
    func prepare() async throws -> ((Data) -> Void)?
    func finish() async throws -> String
    func cancel()
    func attachTranscription(_ id: UUID)
}

extension HaasDictationSession: HaasRecordingSession {}

@MainActor
struct HaasSessionOptions {
    let inputTarget: HaasPasteTarget?
    let replacementPlan: WordReplacementPlan
    let punctuationMode: HaasPunctuationMode
    let delivery: HaasInputDelivery
    let onPartialTranscript: (String) -> Void
    let onFailure: (Error) -> Void
}

typealias HaasSessionFactory = @MainActor (HaasSessionOptions) throws -> any HaasRecordingSession

@MainActor
final class HaasEngine: ObservableObject {
    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var partialTranscript = ""
    @Published var errorMessage: String?
    @Published private(set) var recordedDuration: TimeInterval = 0
    @Published private(set) var hasUnsavedHistory = false
    @Published private(set) var activeRecordingStartID: UUID?
    @Published private(set) var activeAudioURL: URL?

    let recorder: any HaasAudioRecording
    let modelContext: ModelContext
    let inputDelivery: HaasInputDelivery

    @MainActor
    private final class Recording {
        let requestID: UUID
        let audioURL: URL
        let inputTarget: HaasPasteTarget?
        let punctuationMode: HaasPunctuationMode
        var session: (any HaasRecordingSession)?
        var startedUptime: TimeInterval?
        var duration: TimeInterval = 0
        var hardwareRequested = false
        var audioStopTask: Task<Void, Never>?
        var cancelled = false
        var failure: Error?
        var finalized = false

        init(id: UUID, audioURL: URL, target: HaasPasteTarget?, punctuationMode: HaasPunctuationMode) {
            requestID = id
            self.audioURL = audioURL
            inputTarget = target
            self.punctuationMode = punctuationMode
        }
    }

    private let sessionFactory: HaasSessionFactory
    private let recordingsDirectory: URL
    private var active: Recording?
    private var isPreparingTermination = false
    private var startTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var sleepSubscription: AnyCancellable?
    private var pendingHistoryLinks: [UUID: UUID] = [:]
    private let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "HaasEngine")

    init(
        modelContext: ModelContext,
        recorder: (any HaasAudioRecording)? = nil,
        sessionFactory: HaasSessionFactory? = nil,
        inputDelivery: HaasInputDelivery? = nil,
        recordingsDirectory: URL? = nil
    ) {
        self.modelContext = modelContext
        self.recorder = recorder ?? Recorder()
        self.sessionFactory = sessionFactory ?? Self.makeLiveSession
        self.inputDelivery = inputDelivery ?? .shared
        self.recordingsDirectory = recordingsDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppStorageIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        sleepSubscription = LifecycleObserver.shared.publisher(for: [.systemWillSleep])
            .sink { [weak self] _ in
                Task { @MainActor in await self?.cancelRecording() }
            }
    }

    @discardableResult
    func startHeldRecording() -> UUID? {
        guard !Task.isCancelled, !isPreparingTermination, recordingState == .idle, active == nil else { return nil }
        if hasUnsavedHistory {
            retrySavingHistory()
            guard !hasUnsavedHistory else { return nil }
        }
        let target = HaasPasteTarget.capture()
        let id = UUID()
        let recording = Recording(
            id: id, audioURL: recordingsDirectory.appendingPathComponent("recording_\(id.uuidString).wav"),
            target: target, punctuationMode: .stored
        )
        active = recording
        activeRecordingStartID = id
        activeAudioURL = recording.audioURL
        partialTranscript = ""
        recordedDuration = 0
        errorMessage = nil
        recordingState = .starting

        startTask = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.start(recording)
        }
        // The shortcut owns this request before permission, model, or hardware preparation can wait.
        return id
    }

    func finishHeldShortcutRecording(recordingID: UUID) {
        guard let active, active.requestID == recordingID else { return }
        switch recordingState {
        case .starting: requestCancellation(active)
        case .recording: beginFinishing(active)
        case .idle, .transcribing, .busy: break
        }
    }

    func toggleRecording() async {
        switch recordingState {
        case .idle:
            _ = startHeldRecording()
        case .recording:
            if let active { beginFinishing(active) }
        case .starting:
            await cancelRecording()
        case .transcribing, .busy:
            break
        }
    }

    func cancelRecording(recordingID: UUID? = nil) async {
        guard let recording = active,
            recordingID == nil || recordingID == recording.requestID else { return }
        requestCancellation(recording)
        if let startTask { await startTask.value }
        guard active === recording else { return }
        if let finishTask {
            await finishTask.value
        } else {
            beginFinishing(recording)
            await finishTask?.value
        }
    }

    private func requestCancellation(_ recording: Recording) {
        guard active === recording, !recording.finalized else { return }
        recording.cancelled = true
        recordingState = .busy
        durationTask?.cancel()
        recording.session?.cancel()
        startTask?.cancel()
        if recording.hardwareRequested {
            recorder.cancelPendingStart()
            beginAudioStop(recording)
        }
    }

    func prepareForTermination() async -> Bool {
        isPreparingTermination = true
        defer { isPreparingTermination = false }
        await cancelRecording()
        await recorder.waitForAudioRestoration()
        retrySavingHistory()
        if inputDelivery.hasUnsavedRecovery {
            errorMessage = "保存できていない認識結果があります。保留文をコピーしてから、保存状態を確認してください。"
            return false
        }
        return !hasUnsavedHistory
    }

    func retrySavingHistory() {
        guard hasUnsavedHistory else { return }
        do {
            try modelContext.save()
            hasUnsavedHistory = false
            linkSavedHistory()
            errorMessage = nil
        } catch {
            logger.error("History save retry failed: \(String(reflecting: error), privacy: .private)")
            errorMessage = "履歴を保存できません。文章と録音は保持しています。保存先の空き容量を確認して再試行してください。"
        }
    }

    func copyLastTranscription() {
        do {
            guard let text = try lastTranscriptionText(), !text.isEmpty else {
                errorMessage = "コピーできる認識結果がありません。"
                return
            }
            if !ClipboardManager.setClipboard(text) { errorMessage = "クリップボードへコピーできませんでした。" }
        } catch {
            errorMessage = "履歴を読み込めませんでした。"
        }
    }

    func pasteLastTranscription() {
        guard recordingState == .idle else { return }
        let target = HaasPasteTarget.capture()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let text = try lastTranscriptionText(), !text.isEmpty else {
                    errorMessage = "貼り付けられる認識結果がありません。"
                    return
                }
                guard let target else {
                    errorMessage = "入力先を確認できません。入力欄を選ぶか、履歴からコピーしてください。"
                    return
                }
                let outcome = await CursorPaster.startPasteAtCursor(text) {
                    self.recordingState == .idle && target.rejectionReason() == nil
                }.value
                if outcome.result != .commandPosted {
                    errorMessage = "入力を確認できませんでした。入力先を確認し、必要なら履歴からコピーしてください。"
                }
            } catch {
                errorMessage = "履歴を読み込めませんでした。"
            }
        }
    }

    private func start(_ recording: Recording) async {
        do {
            try checkActive(recording)
            guard await recorder.requestMicrophoneAccess() else { throw RecordingError.microphonePermission }
            try checkActive(recording)
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
            let plan = try WordReplacementService.shared.snapshot(using: modelContext)
            let options = HaasSessionOptions(
                inputTarget: recording.inputTarget, replacementPlan: plan,
                punctuationMode: recording.punctuationMode, delivery: inputDelivery,
                onPartialTranscript: { [weak self, weak recording] text in
                    guard let self, let recording, self.active === recording,
                        self.recordingState == .starting || self.recordingState == .recording
                    else { return }
                    self.partialTranscript = text
                },
                onFailure: { [weak self, weak recording] error in
                    guard let self, let recording else { return }
                    self.sessionFailed(recording, error: error)
                }
            )
            let session = try sessionFactory(options)
            recording.session = session
            let receiver = try await session.prepare()
            try checkActive(recording)
            recorder.onAudioChunk = receiver
            recorder.onRecordingFailure = { [weak self, weak recording] error in
                guard let self, let recording else { return }
                self.sessionFailed(recording, error: error)
            }
            recording.hardwareRequested = true
            try await recorder.startRecording(toOutputFile: recording.audioURL)
            try checkActive(recording)
            recording.startedUptime = ProcessInfo.processInfo.systemUptime
            startTask = nil
            recordingState = .recording
            startDurationUpdates(recording)
        } catch {
            if !recording.cancelled { recording.failure = recording.failure ?? error }
            recordingState = .busy
            recording.session?.cancel()
            await stopAudio(recording)
            if let session = recording.session { _ = try? await session.finish() }
            complete(recording)
        }
    }

    private func beginFinishing(_ recording: Recording) {
        guard active === recording, finishTask == nil else { return }
        recordingState = recording.cancelled ? .busy : .transcribing
        durationTask?.cancel()
        finishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await stopAudio(recording)
            if let session = recording.session {
                do {
                    let text = try await session.finish()
                    if active === recording { partialTranscript = text }
                } catch {
                    if !recording.cancelled { recording.failure = recording.failure ?? error }
                }
                session.cancel()
            }
            complete(recording)
        }
    }

    private func beginAudioStop(_ recording: Recording) {
        guard recording.hardwareRequested, recording.audioStopTask == nil else { return }
        let recorder = self.recorder
        recording.audioStopTask = Task { @MainActor in
            await recorder.stopRecording(expectedGeneration: nil)
        }
    }

    private func stopAudio(_ recording: Recording) async {
        if recording.hardwareRequested {
            beginAudioStop(recording)
            await recording.audioStopTask?.value
            recording.hardwareRequested = false
        }
        recorder.onAudioChunk = nil
        recorder.onRecordingFailure = nil
        if let started = recording.startedUptime {
            recording.duration = max(0, ProcessInfo.processInfo.systemUptime - started)
        }
        if let file = try? AVAudioFile(forReading: recording.audioURL), file.processingFormat.sampleRate > 0 {
            recording.duration = Double(file.length) / file.processingFormat.sampleRate
        }
        recordedDuration = recording.duration
    }

    private func complete(_ recording: Recording) {
        guard active === recording, !recording.finalized else { return }
        recording.finalized = true
        durationTask?.cancel()
        durationTask = nil
        let text = recording.session?.recognizedText ?? ""
        let hasAudio = FileManager.default.fileExists(atPath: recording.audioURL.path)
        if hasAudio || !text.isEmpty {
            let status: TranscriptionStatus = recording.cancelled ? .canceled : (recording.failure == nil ? .completed : .failed)
            let row = Transcription(
                text: text, duration: recording.duration,
                audioFileURL: hasAudio ? recording.audioURL.absoluteString : nil,
                transcriptionModelName: "Haas-ja Q8", transcriptionStatus: status
            )
            modelContext.insert(row)
            if let session = recording.session { pendingHistoryLinks[row.id] = session.sessionID }
            do {
                try modelContext.save()
                linkSavedHistory()
            } catch {
                hasUnsavedHistory = true
                logger.error("History save failed: \(String(reflecting: error), privacy: .private)")
                errorMessage = "履歴を保存できません。文章と録音は保持しています。保存先の空き容量を確認してください。"
            }
        }
        if let failure = recording.failure, !recording.cancelled, !hasUnsavedHistory {
            logger.error("Recording failed: \(String(reflecting: failure), privacy: .private)")
            errorMessage = (failure as? RecordingError)?.errorDescription
                ?? (failure as? CoreAudioRecorderError)?.errorDescription
                ?? HaasErrorPresentation.message(for: failure, fallback: "音声入力を完了できませんでした。録音や保留文を確認してください。")
        }
        active = nil
        activeRecordingStartID = nil
        activeAudioURL = nil
        startTask = nil
        finishTask = nil
        recordingState = .idle
        if !hasUnsavedHistory {
            do { _ = try HaasHistoryMaintenance.shared.run(context: modelContext) }
            catch { logger.error("History cleanup failed: \(String(reflecting: error), privacy: .private)") }
        }
    }

    private func linkSavedHistory() {
        for (transcriptionID, sessionID) in pendingHistoryLinks {
            inputDelivery.attachTranscription(sessionID: sessionID, transcriptionID: transcriptionID)
        }
        pendingHistoryLinks.removeAll()
    }

    private func sessionFailed(_ recording: Recording, error: Error) {
        guard active === recording, !recording.finalized else { return }
        recording.failure = recording.failure ?? error
        switch recordingState {
        case .starting:
            startTask?.cancel()
            recording.session?.cancel()
            if recording.hardwareRequested {
                recorder.cancelPendingStart()
                beginAudioStop(recording)
            }
        case .recording:
            beginFinishing(recording)
        case .idle, .transcribing, .busy:
            break
        }
    }

    private func checkActive(_ recording: Recording) throws {
        try Task.checkCancellation()
        guard active === recording, !recording.cancelled else { throw CancellationError() }
        if let error = recording.failure { throw error }
    }

    private func startDurationUpdates(_ recording: Recording) {
        durationTask?.cancel()
        durationTask = Task { @MainActor [weak self, weak recording] in
            while !Task.isCancelled {
                guard let self, let recording, self.active === recording,
                    self.recordingState == .recording, let started = recording.startedUptime
                else { return }
                self.recordedDuration = max(0, ProcessInfo.processInfo.systemUptime - started)
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    private func lastTranscriptionText() throws -> String? {
        var request = FetchDescriptor<Transcription>(sortBy: [SortDescriptor(\Transcription.timestamp, order: .reverse)])
        request.fetchLimit = 1
        guard let row = try modelContext.fetch(request).first else { return nil }
        return row.preferredHistoryText
    }

    private static func makeLiveSession(_ options: HaasSessionOptions) throws -> any HaasRecordingSession {
        let settings = HaasSettingsStore.shared
        return HaasDictationSession(
            runtime: try settings.runtimeConfiguration(), words: try settings.vocabularySnapshot(),
            inputTarget: options.inputTarget, onPartialTranscript: options.onPartialTranscript,
            replacementPlan: options.replacementPlan, punctuationMode: options.punctuationMode,
            delivery: options.delivery, onFailure: options.onFailure
        )
    }

    private enum RecordingError: LocalizedError {
        case microphonePermission
        var errorDescription: String? { "録音するには、システム設定でマイクへのアクセスを許可してください。" }
    }
}
