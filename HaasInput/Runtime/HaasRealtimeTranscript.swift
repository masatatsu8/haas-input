import Foundation

enum HaasRealtimeEvent {
    case partial(text: String)
    case committed(id: String, text: String)
    case error(Error)
}

struct HaasServerEvent: Decodable {
    let type: String
    let itemID: String?
    let delta: String?
    let transcript: String?
    let stop: String?
    let error: ServerError?
    let session: Session?

    enum CodingKeys: String, CodingKey {
        case type, delta, transcript, stop, error, session
        case itemID = "item_id"
    }

    struct ServerError: Decodable {
        let message: String
        let code: String?
    }

    struct Session: Decodable {
        let audio: Audio
        struct Audio: Decodable {
            let input: Input
            struct Input: Decodable {
                let turnDetection: TurnDetection?
                enum CodingKeys: String, CodingKey { case turnDetection = "turn_detection" }
                struct TurnDetection: Decodable { let type: String }
            }
        }
    }
}

struct HaasRealtimeTranscript {
    private var itemOrder: [String] = []
    private var committedIDs: Set<String> = []
    private var completed: [String: String] = [:]
    private var deltas: [String: String] = [:]
    private var emittedIDs: Set<String> = []

    var isComplete: Bool { committedIDs.allSatisfy { completed[$0] != nil } }
    var fullText: String { itemOrder.compactMap { completed[$0] }.joined() }
    var preview: String { itemOrder.map { completed[$0] ?? deltas[$0] ?? "" }.joined() }

    mutating func receive(_ event: HaasServerEvent) throws -> [HaasRealtimeEvent] {
        switch event.type {
        case "input_audio_buffer.speech_started":
            remember(try itemID(of: event))
            return []
        case "input_audio_buffer.committed":
            let id = try itemID(of: event)
            remember(id)
            committedIDs.insert(id)
            return completedEvents()
        case "conversation.item.input_audio_transcription.delta":
            let id = try itemID(of: event)
            guard let delta = event.delta else { throw HaasRuntimeError.protocolViolation("delta がありません。") }
            remember(id)
            guard completed[id] == nil else { return [] }
            deltas[id, default: ""] += delta
            return [.partial(text: preview)]
        case "conversation.item.input_audio_transcription.completed":
            let id = try itemID(of: event)
            guard event.stop == "complete" else {
                throw HaasRuntimeError.recognition("認識上限に達した区間は自動入力しません。")
            }
            guard let text = event.transcript else {
                throw HaasRuntimeError.protocolViolation("確定文字列がありません。")
            }
            if let previous = completed[id] {
                guard previous == text else {
                    throw HaasRuntimeError.protocolViolation("確定済み区間の文字列が変更されました。")
                }
                return []
            }
            remember(id)
            completed[id] = text
            deltas.removeValue(forKey: id)
            return completedEvents() + [.partial(text: preview)]
        case "conversation.item.input_audio_transcription.failed", "error":
            throw HaasRuntimeError.recognition(event.error?.message ?? "認識サーバーがエラーを返しました。")
        default:
            return []
        }
    }

    private mutating func remember(_ id: String) {
        if !itemOrder.contains(id) { itemOrder.append(id) }
    }

    private func itemID(of event: HaasServerEvent) throws -> String {
        guard let id = event.itemID, !id.isEmpty else {
            throw HaasRuntimeError.protocolViolation("区間 ID がありません。")
        }
        return id
    }

    private mutating func completedEvents() -> [HaasRealtimeEvent] {
        var events: [HaasRealtimeEvent] = []
        for id in itemOrder {
            guard committedIDs.contains(id), let text = completed[id] else { break }
            if emittedIDs.insert(id).inserted {
                events.append(.committed(id: id, text: text))
            }
        }
        return events
    }
}
