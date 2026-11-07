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

    func testResamplesStereo48kHzToMono24kHzAcrossUnevenChunks() throws {
        let rate = 48_000.0
        let mono = sine(frequency: 1_000, amplitude: 0.5, sampleRate: rate, frames: 48_000)
        let stereo = mono.flatMap { [$0, $0] }
        let converted = try resample(stereo, sampleRate: rate, channelCount: 2)
        XCTAssertEqual(converted.count, 24_000)
        let crossings = (2_401..<21_600).filter { converted[$0 - 1] <= 0 && converted[$0] > 0 }.count
        XCTAssertEqual(Double(crossings), 800, accuracy: 2)
        XCTAssertEqual(rms(converted[2_400..<21_600]), 0.5 / 2.squareRoot() * 32_767, accuracy: 300)
    }

    func testResamples44_1kHzWithoutDroppingFramesAtBufferBoundaries() throws {
        let rate = 44_100.0
        let input = sine(frequency: 1_000, amplitude: 0.5, sampleRate: rate, frames: 44_100)
        let converted = try resample(input, sampleRate: rate, channelCount: 1)
        XCTAssertEqual(converted.count, 24_000)
        let crossings = (2_401..<21_600).filter { converted[$0 - 1] <= 0 && converted[$0] > 0 }.count
        XCTAssertEqual(Double(crossings), 800, accuracy: 2)
    }

    func testFiltersFrequenciesAbove12kHzBeforeDownsampling() throws {
        let rate = 48_000.0
        let input = sine(frequency: 18_000, amplitude: 0.5, sampleRate: rate, frames: 48_000)
        let converted = try resample(input, sampleRate: rate, channelCount: 1)
        // Without a low-pass filter, 18 kHz folds back to 6 kHz at nearly full level (about 11,585).
        XCTAssertLessThan(rms(converted[2_400..<21_600]), 100)
    }

    func testClipsOutOfRangeSamplesInsteadOfWrappingAround() throws {
        let converted = try resample(Array(repeating: 1.5, count: 4_800), sampleRate: 48_000, channelCount: 1)
        XCTAssertTrue(converted[600..<1_800].allSatisfy { $0 == Int16.max })
    }

    func testConverterRejectsInputAfterFinish() throws {
        let converter = try HaasPCMConverter(inputSampleRate: 48_000)
        _ = try converter.finish()
        XCTAssertTrue(try converter.finish().isEmpty)
        let samples: [Float32] = [0, 0]
        XCTAssertThrowsError(try samples.withUnsafeBufferPointer { buffer in
            try converter.convert(interleaved: buffer.baseAddress!, frameCount: 2, channelCount: 1)
        })
    }

    private func sine(frequency: Double, amplitude: Double, sampleRate: Double, frames: Int) -> [Float32] {
        (0..<frames).map { Float32(sin(2 * Double.pi * frequency * Double($0) / sampleRate) * amplitude) }
    }

    /// Feeds uneven chunks, including one larger than the converter's buffer, then flushes the tail.
    private func resample(_ samples: [Float32], sampleRate: Double, channelCount: Int) throws -> [Int16] {
        let converter = try HaasPCMConverter(inputSampleRate: sampleRate, maximumInputFrames: 4_096)
        let frameSizes = [1, 19, 997, 384, 5_000, 512, 471]
        let totalFrames = samples.count / channelCount
        var output = Data()
        var offset = 0
        var chunk = 0
        try samples.withUnsafeBufferPointer { buffer in
            while offset < totalFrames {
                let frames = min(frameSizes[chunk % frameSizes.count], totalFrames - offset)
                output.append(try converter.convert(
                    interleaved: buffer.baseAddress! + offset * channelCount,
                    frameCount: frames, channelCount: channelCount))
                offset += frames
                chunk += 1
            }
        }
        output.append(try converter.finish())
        return output.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    private func rms(_ samples: ArraySlice<Int16>) -> Double {
        (samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
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
