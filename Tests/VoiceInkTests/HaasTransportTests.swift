import Foundation
import XCTest
@testable import VoiceInk

final class HaasTransportTests: XCTestCase {
    func testFinalTextReplacesDeltasAndDuplicateCompletionDoesNotRedeliver() throws {
        var transcript = HaasRealtimeTranscript()
        _ = try transcript.receive(event("input_audio_buffer.speech_started", id: "a"))
        _ = try transcript.receive(event("conversation.item.input_audio_transcription.delta", id: "a", delta: "ボイスインク"))
        XCTAssertEqual(transcript.preview, "ボイスインク")
        _ = try transcript.receive(event("input_audio_buffer.committed", id: "a"))
        XCTAssertFalse(transcript.isComplete)

        let completed = try event(
            "conversation.item.input_audio_transcription.completed", id: "a", transcript: "VoiceInk", stop: "complete")
        let first = try transcript.receive(completed)
        XCTAssertEqual(commits(first).map(\.text), ["VoiceInk"])
        XCTAssertEqual(transcript.fullText, "VoiceInk")
        XCTAssertEqual(transcript.preview, "VoiceInk")
        XCTAssertTrue(transcript.isComplete)
        XCTAssertTrue(try transcript.receive(completed).isEmpty)
    }

    func testOutOfOrderResultsAreDeliveredInAudioOrderWithExactBrandSpelling() throws {
        var transcript = HaasRealtimeTranscript()
        for id in ["a", "b"] {
            _ = try transcript.receive(event("input_audio_buffer.speech_started", id: id))
            _ = try transcript.receive(event("input_audio_buffer.committed", id: id))
        }
        let later = try transcript.receive(event(
            "conversation.item.input_audio_transcription.completed", id: "b", transcript: "Amazon S3。", stop: "complete"))
        XCTAssertTrue(commits(later).isEmpty)
        let ordered = try transcript.receive(event(
            "conversation.item.input_audio_transcription.completed", id: "a", transcript: "JiHAN Prime は", stop: "complete"))
        XCTAssertEqual(commits(ordered).map(\.id), ["a", "b"])
        XCTAssertEqual(transcript.fullText, "JiHAN Prime はAmazon S3。")
    }

    func testTruncatedAndFailedResultsCannotBecomeCommittedText() throws {
        for json in [
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"途中","stop":"model_limit"}"#,
            #"{"type":"conversation.item.input_audio_transcription.failed","item_id":"a","error":{"code":"out_of_memory","message":"failed"}}"#,
        ] {
            var transcript = HaasRealtimeTranscript()
            _ = try transcript.receive(event("input_audio_buffer.committed", id: "a"))
            XCTAssertThrowsError(try transcript.receive(JSONDecoder().decode(HaasServerEvent.self, from: Data(json.utf8))))
            XCTAssertEqual(transcript.fullText, "")
            XCTAssertFalse(transcript.isComplete)
        }
    }

    func testStatefulResamplingPreservesDurationAndPitchAcrossUnevenChunks() throws {
        let converter = try HaasPCMConverter()
        let samples = (0..<16_000).map { index in
            Int16((sin(2 * Double.pi * 1_000 * Double(index) / 16_000) * 16_000).rounded())
        }
        let input = samples.withUnsafeBytes { Data($0) }
        let frameSizes = [1, 19, 997, 384, 1_537]
        var offset = 0
        var chunk = 0
        var output = Data()
        while offset < input.count {
            let end = min(offset + frameSizes[chunk % frameSizes.count] * 2, input.count)
            output.append(try converter.convert(input.subdata(in: offset..<end)))
            offset = end
            chunk += 1
        }
        output.append(try converter.finish())
        XCTAssertEqual(output.count, 24_000 * 2)
        let converted: [Int16] = output.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let crossings = (2_401..<21_600).filter { converted[$0 - 1] <= 0 && converted[$0] > 0 }.count
        XCTAssertEqual(Double(crossings), 800, accuracy: 2)
        XCTAssertTrue(try converter.finish().isEmpty)
    }

    private func event(
        _ type: String, id: String, delta: String? = nil, transcript: String? = nil, stop: String? = nil
    ) throws -> HaasServerEvent {
        var payload = ["type": type, "item_id": id]
        payload["delta"] = delta
        payload["transcript"] = transcript
        payload["stop"] = stop
        return try JSONDecoder().decode(HaasServerEvent.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func commits(_ events: [HaasRealtimeEvent]) -> [(id: String, text: String)] {
        events.compactMap {
            if case .committed(let id, let text) = $0 { return (id, text) }
            return nil
        }
    }
}
