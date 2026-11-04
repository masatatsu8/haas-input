import Foundation
import os

enum HaasSessionError: LocalizedError {
    case audioBacklog

    var errorDescription: String? {
        switch self {
        case .audioBacklog:
            return "音声の送信が追いつかないため停止しました。録音は履歴に保存します。"
        }
    }
}

final class HaasAudioInbox: @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private struct State {
        var isFinished = false
        var failure: Error?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        stream = pair.stream
        continuation = pair.continuation
    }

    func receive(_ data: Data) {
        state.withLock { state in
            guard !state.isFinished else { return }
            if case .dropped = continuation.yield(data) {
                state.failure = HaasSessionError.audioBacklog
                state.isFinished = true
                continuation.finish(throwing: state.failure)
            }
        }
    }

    var failure: Error? { state.withLock { $0.failure } }

    func finish() {
        state.withLock { state in
            state.isFinished = true
            continuation.finish()
        }
    }
}

@MainActor
final class HaasDictationSession {
    private struct PendingFormatting {
        let requestID: UUID
        let itemID: String
        let text: String
    }

    let sessionID = UUID()
    let punctuationMode: HaasPunctuationMode
    private let inputTarget: HaasPasteTarget?
    private let onPartialTranscript: ((String) -> Void)?
    private let onFailure: ((Error) -> Void)?
    private let runtime: HaasRuntimeConfiguration
    private let words: String
    private let delivery: HaasInputDelivery
    private let punctuationWorker: HaasPunctuationWorker
    private let audioInbox = HaasAudioInbox()
    private var client: HaasRealtimeClient?
    private var audioTask: Task<Void, Error>?
    private var failure: Error?
    private var isCancelled = false
    private var isFinished = false
    private var transcript: HaasSessionTranscript
    private let vocabularyWrittenForms: [String]
    private var latestRawPreview = ""
    private var pendingFormatting: PendingFormatting?
    private var formattingWaiters: [CheckedContinuation<Void, Never>] = []
    private let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "HaasDictationSession")

    var recognizedText: String { transcript.text }

    init(
        runtime: HaasRuntimeConfiguration, words: String,
        inputTarget: HaasPasteTarget?, onPartialTranscript: ((String) -> Void)?,
        replacementPlan: WordReplacementPlan, vocabularyEntries: [HaasVocabularyEntry] = [],
        punctuationMode: HaasPunctuationMode = .fast,
        punctuationWorker: HaasPunctuationWorker? = nil, delivery: HaasInputDelivery? = nil,
        onFailure: ((Error) -> Void)? = nil
    ) {
        self.runtime = runtime
        self.words = words
        self.inputTarget = inputTarget
        self.onPartialTranscript = onPartialTranscript
        self.onFailure = onFailure
        self.punctuationMode = punctuationMode
        self.punctuationWorker = punctuationWorker ?? .shared
        self.delivery = delivery ?? .shared
        let vocabulary = HaasVocabularyMatcher(entries: vocabularyEntries)
        vocabularyWrittenForms = vocabulary.writtenForms
        transcript = HaasSessionTranscript(replacements: replacementPlan, vocabulary: vocabulary)
    }

    func prepare() async throws -> ((Data) -> Void)? {
        try await delivery.begin(sessionID: sessionID, target: inputTarget)
        try checkCancellation()
        if punctuationMode == .natural { punctuationWorker.prewarm() }
        let client = HaasRealtimeClient(configuration: runtime) { [weak self] event in
            self?.receive(event)
        }
        self.client = client
        do {
            try await client.connect(vocabulary: words)
            try checkCancellation()
            let inbox = audioInbox
            audioTask = Task { @MainActor [weak self] in
                do {
                    for try await data in inbox.stream {
                        if let error = inbox.failure { throw error }
                        try Task.checkCancellation()
                        try await client.sendAudioChunk(data)
                    }
                } catch {
                    self?.fail(error)
                    throw error
                }
            }
            return inbox.receive
        } catch {
            fail(error)
            throw error
        }
    }

    func finish() async throws -> String {
        audioInbox.finish()
        do {
            try checkCancellation()
            try await audioTask?.value
            if let failure { throw failure }
            guard let client else { throw HaasRuntimeError.notConnected }
            _ = try await client.finish()
            await waitForFormatting()
            if let failure { throw failure }
            try checkCancellation()
            await delivery.finish(sessionID: sessionID)
            isFinished = true
            return transcript.text
        } catch {
            fail(error)
            await delivery.finish(sessionID: sessionID)
            throw error
        }
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelPendingFormatting()
        let cancellationMessage = isFinished || failure != nil
            ? nil : "録音を取り消しました。既に入力した文章は変更せず、未入力分は保存しています。"
        delivery.cancel(sessionID: sessionID, message: cancellationMessage)
        audioInbox.finish()
        audioTask?.cancel()
        client?.cancel()
    }

    func fail(_ error: Error) {
        guard failure == nil, !isCancelled, !isFinished else { return }
        failure = error
        logger.error("Haas session failed: \(String(reflecting: error), privacy: .private)")
        let message = (error as? HaasSessionError)?.errorDescription
            ?? HaasErrorPresentation.message(for: error, fallback: "音声認識を停止しました。もう一度録音を開始してください。")
        cancelPendingFormatting()
        delivery.pause(sessionID: sessionID, message: message)
        audioInbox.finish()
        client?.cancel()
        onFailure?(error)
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if isCancelled { throw CancellationError() }
    }

    func receive(_ event: HaasRealtimeEvent) {
        guard !isCancelled, !isFinished, failure == nil else { return }
        switch event {
        case .partial(let text):
            latestRawPreview = text
            publishPreview()
        case .committed(let id, let text):
            let receivedAt = ContinuousClock.now
            guard let base = transcript.commit(id: id, rawText: text), !base.isEmpty else { return }
            if punctuationMode == .fast {
                let formatted = HaasPunctuationFormatter.fast(base)
                transcript.finalize(id: id, text: formatted)
                delivery.accept(sessionID: sessionID, itemID: id, text: formatted)
            } else if pendingFormatting != nil {
                transcript.finalize(id: id, text: base)
                delivery.accept(sessionID: sessionID, itemID: id, text: base)
            } else {
                let requestID = UUID()
                guard delivery.accept(sessionID: sessionID, itemID: id, text: base, formattingHoldID: requestID) else {
                    transcript.finalize(id: id, text: base)
                    publishPreview()
                    return
                }
                pendingFormatting = PendingFormatting(requestID: requestID, itemID: id, text: base)
                if !punctuationWorker.submit(base, requestID: requestID, receivedAt: receivedAt, completion: { [weak self] candidate in
                    self?.completeFormatting(requestID: requestID, candidate: candidate)
                }) {
                    completeFormatting(requestID: requestID, candidate: nil)
                }
            }
            publishPreview()
        case .error(let error):
            fail(error)
        }
    }

    private func completeFormatting(requestID: UUID, candidate: String?) {
        guard !isCancelled, !isFinished, failure == nil,
            let pending = pendingFormatting, pending.requestID == requestID
        else { return }
        let text = candidate ?? pending.text
        let applied = delivery.completeHeldFormatting(
            sessionID: sessionID, itemID: pending.itemID, requestID: requestID, text: text
        )
        transcript.finalize(id: pending.itemID, text: applied ? text : pending.text)
        pendingFormatting = nil
        resumeFormattingWaiters()
        publishPreview()
    }

    private func cancelPendingFormatting() {
        guard let pending = pendingFormatting else { return }
        pendingFormatting = nil
        punctuationWorker.cancel(requestID: pending.requestID)
        transcript.finalize(id: pending.itemID, text: pending.text)
        resumeFormattingWaiters()
    }

    private func waitForFormatting() async {
        await withTaskCancellationHandler {
            guard pendingFormatting != nil, !Task.isCancelled else { return }
            await withCheckedContinuation { formattingWaiters.append($0) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func resumeFormattingWaiters() {
        let waiters = formattingWaiters
        formattingWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func publishPreview() {
        onPartialTranscript?(transcript.preview(rawText: latestRawPreview))
    }

    func attachTranscription(_ id: UUID) {
        delivery.attachTranscription(sessionID: sessionID, transcriptionID: id)
    }
}

