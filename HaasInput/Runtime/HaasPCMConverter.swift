import AVFoundation
import Foundation

final class HaasPCMConverter {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var ended = false

    init() throws {
        guard let input = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
            let output = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: input, to: output)
        else { throw HaasRuntimeError.invalidAudio }
        inputFormat = input
        outputFormat = output
        self.converter = converter
    }

    func convert(_ data: Data) throws -> Data {
        guard !ended, data.count.isMultiple(of: 2), data.count <= 1_048_576 else {
            throw HaasRuntimeError.invalidAudio
        }
        guard !data.isEmpty else { return Data() }
        let frames = AVAudioFrameCount(data.count / 2)
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
            let samples = input.int16ChannelData?[0]
        else { throw HaasRuntimeError.invalidAudio }
        input.frameLength = frames
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: data.count))
        return try run(input: input, endOfStream: false)
    }

    func finish() throws -> Data {
        guard !ended else { return Data() }
        ended = true
        return try run(input: nil, endOfStream: true)
    }

    private func run(input: AVAudioPCMBuffer?, endOfStream: Bool) throws -> Data {
        var supplied = false
        var result = Data()
        let capacity = max(4_096, AVAudioFrameCount(Double(input?.frameLength ?? 0) * 1.5) + 512)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw HaasRuntimeError.invalidAudio
        }

        // Keep the converter across chunks. Apple's input block distinguishes a temporary gap from EOF:
        // https://developer.apple.com/documentation/avfaudio/avaudioconverter/convert(to:error:withinputfrom:)
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let input, !supplied {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            guard status != .error, let samples = output.int16ChannelData?[0] else {
                throw HaasRuntimeError.invalidAudio
            }
            result.append(Data(bytes: samples, count: Int(output.frameLength) * 2))
            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return result
            case .error:
                throw HaasRuntimeError.invalidAudio
            @unknown default:
                throw HaasRuntimeError.invalidAudio
            }
        }
    }
}
