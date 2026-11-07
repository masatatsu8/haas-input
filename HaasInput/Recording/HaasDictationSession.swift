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
        /// accept に渡した文。速度優先の規則を当てたもので、AI の結果を使えないときはこの文で決める。
        /// 前の区切りの保留した「。」を付けたときは、その「。」を含む
        let deliveredText: String
        let attachesHeldPeriod: Bool
        /// 整形中に届いた次の区切りの整形前の文。この区切りの末尾の「。」を、これで決める
        var nextBase: String?
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
    private let protectedTerms: [String]
    private var latestRawPreview = ""
    private var pendingFormatting: PendingFormatting?
    /// 末尾の「。」を外して受け渡し、次の区切りを待っている区切りの id
    private var heldPeriodItemID: String?
    /// 認識の最後の区切りまで受け取った。この後に整形が終わる区切りには、もう次の区切りが来ない
    private var recognitionEnded = false
    private var formattingWaiters: [CheckedContinuation<Void, Never>] = []
    /// 端末内 AI を使うモードで、区切りごとに句読点を決めた経路
    private(set) var punctuationRoutes: [String: HaasPunctuationRoute] = [:]
    private let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "HaasDictationSession")
    private let punctuationLogger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "HaasPunctuation")

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
        self.punctuationWorker = punctuationWorker ?? .forMode(punctuationMode)
        self.delivery = delivery ?? .shared
        let vocabulary = HaasVocabularyMatcher(entries: vocabularyEntries)
        var seenTerms: Set<String> = []
        protectedTerms = (vocabulary.writtenForms + replacementPlan.replacementTexts).filter { seenTerms.insert($0).inserted }
        transcript = HaasSessionTranscript(replacements: replacementPlan, vocabulary: vocabulary)
    }

    func prepare() async throws -> ((Data) -> Void)? {
        try await delivery.begin(sessionID: sessionID, target: inputTarget)
        try checkCancellation()
        if punctuationMode.usesOnDeviceModel { punctuationWorker.prewarm() }
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
        } catch {
            fail(error)
            await delivery.finish(sessionID: sessionID)
            throw error
        }
        return try await finishAfterRecognition()
    }

    /// 認識の最後の区切りを受け取った後の仕上げ。整形を待ってから、配送を終える
    func finishAfterRecognition() async throws -> String {
        recognitionEnded = true
        do {
            await waitForFormatting()
            if let failure { throw failure }
            try checkCancellation()
            deliverHeldPeriod()
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
        heldPeriodItemID = nil
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
        heldPeriodItemID = nil
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
            let attachesHeldPeriod = resolveHeldPeriod(nextBase: base)
            if punctuationMode == .fast || pendingFormatting != nil {
                // 整形中の区切りの末尾の「。」はまだ決まっていないので、この区切りの頭には付けない。
                // 整形が終わったときに、最初に届いたこの区切りの頭で決める
                if pendingFormatting != nil { recordPunctuationRoute(.skippedWhileFormatting, itemID: id) }
                if pendingFormatting?.nextBase == nil { pendingFormatting?.nextBase = base }
                var formatted = HaasPunctuationFormatter.fast(base)
                if attachesHeldPeriod { formatted = HaasPunctuationFormatter.attachingHeldPeriod(to: formatted) }
                let split = HaasPunctuationFormatter.splittingHeldPeriod(formatted)
                transcript.finalize(id: id, text: split.body)
                delivery.accept(sessionID: sessionID, itemID: id, text: split.body)
                if split.held { heldPeriodItemID = id }
            } else {
                let requestID = UUID()
                // AI の結果を使えないときや配送が止まったときも、台帳と記録に句読点のある同じ文が残るよう、
                // 受け渡す時点で速度優先の規則を当てておく
                let fallback = HaasPunctuationFormatter.fast(base)
                let delivered = attachesHeldPeriod ? HaasPunctuationFormatter.attachingHeldPeriod(to: fallback) : fallback
                guard delivery.accept(sessionID: sessionID, itemID: id, text: delivered, formattingHoldID: requestID) else {
                    recordPunctuationRoute(.notAccepted, itemID: id)
                    transcript.finalize(id: id, text: delivered)
                    publishPreview()
                    return
                }
                pendingFormatting = PendingFormatting(
                    requestID: requestID, itemID: id, deliveredText: delivered,
                    attachesHeldPeriod: attachesHeldPeriod)
                if !punctuationWorker.submit(base, requestID: requestID, receivedAt: receivedAt,
                    protectedTerms: protectedTerms.filter(base.contains), completion: { [weak self] outcome in
                    self?.completeFormatting(requestID: requestID, candidate: outcome.candidate, route: outcome.route)
                }) {
                    completeFormatting(
                        requestID: requestID, candidate: nil,
                        route: punctuationWorker.declinedRoute(receivedAt: receivedAt))
                }
            }
            publishPreview()
        case .error(let error):
            fail(error)
        }
    }

    private func completeFormatting(requestID: UUID, candidate: String?, route: HaasPunctuationRoute) {
        guard !isCancelled, !isFinished, failure == nil,
            let pending = pendingFormatting, pending.requestID == requestID
        else { return }
        var text = pending.deliveredText
        if let candidate {
            text = pending.attachesHeldPeriod ? HaasPunctuationFormatter.attachingHeldPeriod(to: candidate) : candidate
        }
        let split = HaasPunctuationFormatter.splittingHeldPeriod(text)
        var holdsPeriod = false
        if split.held {
            if let nextBase = pending.nextBase {
                if !HaasPunctuationFormatter.startsSentence(nextBase) { text = split.body }
            } else {
                // 次が来ないとわかっていれば保留しない。「。」を別に貼ると、前の貼り付けの後始末を待って約2秒遅れる
                if !recognitionEnded {
                    text = split.body
                    holdsPeriod = true
                }
            }
        }
        let applied = delivery.completeHeldFormatting(
            sessionID: sessionID, itemID: pending.itemID, requestID: requestID, text: text
        )
        recordPunctuationRoute(route == .formatted && !applied ? .notApplied : route, itemID: pending.itemID)
        // 台帳に残らなかった文で記録を確定しない。false なら accept の時の文が台帳に残っている
        transcript.finalize(id: pending.itemID, text: applied ? text : pending.deliveredText)
        if applied, holdsPeriod { heldPeriodItemID = pending.itemID }
        pendingFormatting = nil
        resumeFormattingWaiters()
        publishPreview()
    }

    private func cancelPendingFormatting() {
        guard let pending = pendingFormatting else { return }
        pendingFormatting = nil
        punctuationWorker.cancel(requestID: pending.requestID)
        recordPunctuationRoute(.cancelled, itemID: pending.itemID)
        transcript.finalize(id: pending.itemID, text: pending.deliveredText)
        resumeFormattingWaiters()
    }

    /// 文と AI の出力は残さず、経路とモードだけを残す
    private func recordPunctuationRoute(_ route: HaasPunctuationRoute, itemID: String) {
        punctuationRoutes[itemID] = route
        punctuationLogger.notice(
            "punctuation route=\(route.rawValue, privacy: .public) mode=\(self.punctuationMode.rawValue, privacy: .public)")
    }

    /// 保留中の「。」を、次の区切りの整形前の文で解く。付けるなら true
    private func resolveHeldPeriod(nextBase: String) -> Bool {
        guard heldPeriodItemID != nil else { return false }
        heldPeriodItemID = nil
        return HaasPunctuationFormatter.startsSentence(nextBase)
    }

    /// 録音を止めたときに残っている「。」を、文が「。」だけの区切りとして受け渡す。配送が止まっていても台帳には入る
    private func deliverHeldPeriod() {
        guard let itemID = heldPeriodItemID else { return }
        heldPeriodItemID = nil
        let id = itemID + "-period"
        guard transcript.appendHeldPeriod(id: id) else { return }
        delivery.accept(sessionID: sessionID, itemID: id, text: "。")
        publishPreview()
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

