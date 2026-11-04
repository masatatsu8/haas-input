import Foundation

@MainActor
final class HaasRealtimeClient {
    private enum State { case idle, connecting, connected, finishing, finished, failed, cancelled }
    private struct Waiter {
        let id: UUID
        let condition: () -> Bool
        let continuation: CheckedContinuation<Void, Error>
        let deadline: Task<Void, Never>
    }

    private let server: HaasSpeechServer
    private let onEvent: @MainActor (HaasRealtimeEvent) -> Void
    private var state: State = .idle
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendTail: Task<Void, Error>?
    private var waiter: Waiter?
    private var transcript = HaasRealtimeTranscript()
    private var failure: Error?
    private var sessionCreated = false
    private var sessionConfigured = false
    private var drainRequested = false
    private var drainAcknowledged = false
    private var pendingAudioBytes = 0
    private let maximumPendingAudioBytes = 1_048_576

    init(configuration: HaasRuntimeConfiguration, onEvent: @escaping @MainActor (HaasRealtimeEvent) -> Void) {
        server = HaasSpeechServer(configuration: configuration)
        self.onEvent = onEvent
        server.onUnexpectedExit = { [weak self] error in self?.fail(error) }
    }

    deinit {
        receiveTask?.cancel()
        sendTail?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    func connect(vocabulary: String) async throws {
        guard state == .idle else { throw HaasRuntimeError.protocolViolation("接続はセッションごとに一度だけ開始します。") }
        state = .connecting
        do {
            let baseURL = try await server.start()
            try checkActive()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 3_600
            let session = URLSession(configuration: configuration)
            self.session = session
            try await verifyRuntime(baseURL: baseURL, session: session)
            try checkActive()

            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw HaasRuntimeError.protocolViolation("接続先 URL が不正です。")
            }
            components.scheme = "ws"
            components.path = "/v1/realtime"
            components.queryItems = [URLQueryItem(name: "model", value: "Haas-ja-v1.0")]
            guard let url = components.url else { throw HaasRuntimeError.protocolViolation("接続先 URL が不正です。") }
            let socket = session.webSocketTask(with: url)
            socket.maximumMessageSize = 1_048_576
            self.socket = socket
            socket.resume()
            startReceiving(socket)
            try await waitUntil("接続", seconds: 15) { self.sessionCreated }

            var transcription: [String: Any] = ["model": "Haas-ja-v1.0", "language": "ja"]
            if !vocabulary.isEmpty {
                transcription["words"] = vocabulary
                transcription["words_alpha"] = 2.0
                transcription["words_guard"] = true
            }
            try await send([
                "type": "session.update", "event_id": UUID().uuidString,
                "session": [
                    "type": "transcription",
                    "audio": ["input": [
                        "format": ["type": "audio/pcm", "rate": Int(HaasPCMConverter.outputSampleRate)],
                        "transcription": transcription,
                        "turn_detection": [
                            "type": "server_vad", "threshold": 0.5,
                            "prefix_padding_ms": 300, "silence_duration_ms": 500,
                        ],
                    ]],
                ],
            ])
            try await waitUntil("設定", seconds: 15) { self.sessionConfigured }
            try checkActive()
            state = .connected
        } catch {
            fail(error)
            throw failure ?? error
        }
    }

    /// `data` は 24 kHz・モノラル・16 bit リトルエンディアンの PCM (録音側で変換済み)。
    func sendAudioChunk(_ data: Data) async throws {
        try checkActive()
        guard state == .connected else { throw HaasRuntimeError.notConnected }
        guard data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            let error = HaasRuntimeError.invalidAudio
            fail(error)
            throw error
        }
        guard pendingAudioBytes + data.count <= maximumPendingAudioBytes else {
            let error = HaasRuntimeError.audioBacklog
            fail(error)
            throw error
        }
        pendingAudioBytes += data.count
        do {
            let previous = sendTail
            let task = Task { [weak self] in
                defer { self?.pendingAudioBytes -= data.count }
                try await previous?.value
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                try self.checkActive()
                if !data.isEmpty {
                    try await self.send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
                }
            }
            sendTail = task
            try await task.value
        } catch {
            fail(error)
            throw failure ?? error
        }
    }

    func finish() async throws -> String {
        if state == .finished { return transcript.fullText }
        try checkActive()
        guard state == .connected else { throw HaasRuntimeError.notConnected }
        state = .finishing
        do {
            try await sendTail?.value
            try checkActive()
            // speech.cpp 0.9.4 flushes VAD's last region before session.updated. A raw commit also
            // transcribes trailing silence. https://github.com/nyosegawa/speech.cpp/blob/af6b034918722b65c0f323d984d4644cd4120c77/tools/common/realtime-session.cpp#L437
            drainRequested = true
            try await send([
                "type": "session.update", "event_id": UUID().uuidString,
                "session": ["type": "transcription", "audio": ["input": ["turn_detection": NSNull()]]],
            ])
            try await waitUntil("最後の区間の認識", seconds: 60) {
                self.drainAcknowledged && self.transcript.isComplete
            }
            try checkActive()
            let text = transcript.fullText
            state = .finished
            closeConnection()
            return text
        } catch {
            fail(error)
            throw failure ?? error
        }
    }

    func cancel() {
        guard state != .finished, state != .cancelled, state != .failed else { return }
        state = .cancelled
        failure = CancellationError()
        resolveWaiter(throwing: CancellationError())
        closeConnection()
    }

    private func startReceiving(_ socket: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self else { return }
                    guard self.state == .connecting || self.state == .connected || self.state == .finishing else { return }
                    let data: Data
                    switch message {
                    case .string(let string): data = Data(string.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: throw HaasRuntimeError.protocolViolation("未知の応答形式です。")
                    }
                    try self.receive(JSONDecoder().decode(HaasServerEvent.self, from: data))
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
        }
    }

    private func receive(_ event: HaasServerEvent) throws {
        if event.type == "session.created" { sessionCreated = true }
        if event.type == "session.updated" {
            guard let input = event.session?.audio.input else {
                throw HaasRuntimeError.protocolViolation("セッション設定がありません。")
            }
            if state == .connecting, input.turnDetection?.type == "server_vad" {
                sessionConfigured = true
            } else if state == .finishing, drainRequested, input.turnDetection == nil {
                drainAcknowledged = true
            }
        }
        let isProvisional = event.type == "conversation.item.input_audio_transcription.delta"
            || event.type == "input_audio_buffer.speech_started"
        if !(state == .finishing && isProvisional) {
            for output in try transcript.receive(event) {
                guard state == .connecting || state == .connected || state == .finishing else { return }
                onEvent(output)
            }
        }
        if waiter?.condition() == true { resolveWaiter() }
    }

    private func send(_ object: [String: Any]) async throws {
        try checkActive()
        guard let socket else { throw HaasRuntimeError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw HaasRuntimeError.invalidAudio }
        try await socket.send(.string(text))
        try checkActive()
    }

    private func waitUntil(_ operation: String, seconds: Double, condition: @escaping () -> Bool) async throws {
        try checkActive()
        if condition() { return }
        guard waiter == nil else { throw HaasRuntimeError.protocolViolation("同時に複数の応答を待機しています。") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let id = UUID()
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    guard self?.waiter?.id == id else { return }
                    self?.resolveWaiter(throwing: HaasRuntimeError.timeout(operation))
                }
                waiter = Waiter(id: id, condition: condition, continuation: continuation, deadline: deadline)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func resolveWaiter(throwing error: Error? = nil) {
        guard let pending = waiter else { return }
        waiter = nil
        pending.deadline.cancel()
        if let error { pending.continuation.resume(throwing: error) }
        else { pending.continuation.resume() }
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        if state == .cancelled { throw CancellationError() }
    }

    private func fail(_ error: Error) {
        guard state != .finished, state != .cancelled, state != .failed else { return }
        failure = error
        state = .failed
        resolveWaiter(throwing: error)
        closeConnection()
        onEvent(.error(error))
    }

    private func closeConnection() {
        receiveTask?.cancel()
        receiveTask = nil
        sendTail?.cancel()
        sendTail = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        server.stop()
    }

    private func verifyRuntime(baseURL: URL, session: URLSession) async throws {
        struct Catalog: Decodable {
            let data: [Model]
            struct Model: Decodable {
                let id: String
                let version: String
                let speech: Speech
                struct Speech: Decodable {
                    let task: String
                    let layout: Int?
                    let weightType: String?
                    let device: String?
                    enum CodingKeys: String, CodingKey {
                        case task, layout, device
                        case weightType = "weight_type"
                    }
                }
            }
        }
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("v1/models"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HaasRuntimeError.unsupportedRuntime }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.data.contains(where: {
            $0.id == "Haas-ja-v1.0" && $0.version == "0.9.4" && $0.speech.layout == 4
                && $0.speech.weightType == "Q8_0" && $0.speech.device == "MTL0"
        }), catalog.data.contains(where: { $0.speech.task == "detection" }) else {
            throw HaasRuntimeError.unsupportedRuntime
        }
    }
}
