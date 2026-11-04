import AVFoundation
import Foundation

/// 録音機器の音声を、speech.cpp の Realtime API が受け付ける 24 kHz・モノラル・16 bit PCM へ変換する。
///
/// 複数チャンネルは平均してモノラルにし、AVAudioConverter で帯域制限付きのリサンプリングを行う。
/// 変換器の状態は呼び出しをまたいで保つため、録音バッファの区切りでサンプルが欠けたり段差が出たりしない。
/// https://github.com/nyosegawa/speech.cpp/blob/main/docs/server.md (audio/pcm は 24000 Hz のみ)
final class HaasPCMConverter {
    static let outputSampleRate: Double = 24_000

    let inputSampleRate: Double
    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private var ended = false

    init(inputSampleRate: Double, maximumInputFrames: AVAudioFrameCount = 4_096) throws {
        guard inputSampleRate.isFinite, inputSampleRate > 0, maximumInputFrames > 0,
            let input = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false),
            let output = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Self.outputSampleRate, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: input, to: output),
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: maximumInputFrames),
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: output,
                frameCapacity: AVAudioFrameCount(
                    (Double(maximumInputFrames) * Self.outputSampleRate / inputSampleRate).rounded(.up)) + 1_024)
        else { throw HaasRuntimeError.invalidAudio }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.inputSampleRate = inputSampleRate
        self.converter = converter
        self.inputBuffer = inputBuffer
        self.outputBuffer = outputBuffer
    }

    /// インターリーブされた Float32 のサンプルを変換し、得られた 24 kHz の Int16 PCM を返す。
    /// 変換器の遅延分は次回以降の呼び出しか `finish()` で出力される。
    func convert(interleaved samples: UnsafePointer<Float32>, frameCount: Int, channelCount: Int) throws -> Data {
        guard !ended, frameCount >= 0, channelCount > 0 else { throw HaasRuntimeError.invalidAudio }
        guard let mono = inputBuffer.floatChannelData?[0] else { throw HaasRuntimeError.invalidAudio }

        var result = Data()
        var offset = 0
        let capacity = Int(inputBuffer.frameCapacity)
        while offset < frameCount {
            let frames = min(capacity, frameCount - offset)
            for frame in 0..<frames {
                let base = (offset + frame) * channelCount
                var sample: Float32 = 0
                for channel in 0..<channelCount {
                    sample += samples[base + channel]
                }
                mono[frame] = sample / Float32(channelCount)
            }
            inputBuffer.frameLength = AVAudioFrameCount(frames)
            result.append(try run(input: inputBuffer, endOfStream: false))
            offset += frames
        }
        return result
    }

    /// 変換器に残った末尾の音声を出力する。以後の `convert` は失敗する。
    func finish() throws -> Data {
        guard !ended else { return Data() }
        ended = true
        return try run(input: nil, endOfStream: true)
    }

    private func run(input: AVAudioPCMBuffer?, endOfStream: Bool) throws -> Data {
        var supplied = false
        var result = Data()

        // Keep the converter across chunks. Apple's input block distinguishes a temporary gap from EOF:
        // https://developer.apple.com/documentation/avfaudio/avaudioconverter/convert(to:error:withinputfrom:)
        while true {
            outputBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
                if let input, !supplied {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            guard status != .error, let samples = outputBuffer.int16ChannelData?[0] else {
                throw HaasRuntimeError.invalidAudio
            }
            result.append(Data(bytes: samples, count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size))
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
