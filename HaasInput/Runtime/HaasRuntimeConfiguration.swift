import Foundation

struct HaasRuntimeConfiguration: Equatable, Sendable {
    static let modelFilename = "Haas-616M-ja-v1.0-Q8_0.gguf"
    static let vadFilename = "silero-vad.gguf"
    let executableURL: URL
    let modelURL: URL
    let vadModelURL: URL

    static func bundled(in bundle: Bundle = .main) -> HaasRuntimeConfiguration {
        bundled(directory: bundledDirectory(in: bundle))
    }

    static func bundledDirectory(in bundle: Bundle = .main) -> URL {
        (bundle.resourceURL ?? bundle.bundleURL).appendingPathComponent("Haas", isDirectory: true)
    }

    static func bundled(directory: URL) -> HaasRuntimeConfiguration {
        return HaasRuntimeConfiguration(
            executableURL: directory.appendingPathComponent("speech"),
            modelURL: directory.appendingPathComponent(modelFilename),
            vadModelURL: directory.appendingPathComponent(vadFilename)
        )
    }

    func validate() throws {
        try validateExecutable()
        for url in [modelURL, vadModelURL] { try Self.validateReadableFile(url) }
    }

    func validateExecutable() throws {
        try Self.validateReadableFile(executableURL, requireNonempty: true)
        guard executableURL.isFileURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw HaasRuntimeError.missingAsset(executableURL.path)
        }
        let library = executableURL.deletingLastPathComponent().appendingPathComponent("libspeech.3.dylib")
        try Self.validateReadableFile(library, requireNonempty: true)
    }

    static func validateReadableFile(_ url: URL, requireNonempty: Bool = false) throws {
        guard url.isFileURL,
            FileManager.default.isReadableFile(atPath: url.path),
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true, !requireNonempty || (values.fileSize ?? 0) > 0
        else {
            throw HaasRuntimeError.missingAsset(url.path)
        }
    }
}

enum HaasRuntimeError: LocalizedError, Sendable {
    case missingAsset(String)
    case startup(String)
    case unsupportedRuntime
    case invalidAudio
    case protocolViolation(String)
    case recognition(String)
    case timeout(String)
    case audioBacklog
    case notConnected

    var errorDescription: String? {
        switch self {
        case .missingAsset:
            return "Haas の認識に必要なファイルが見つかりません。ホーム画面で準備状態を確認してください。"
        case .startup:
            return "Haas を起動できませんでした。もう一度録音を開始してください。"
        case .unsupportedRuntime:
            return "Haas の認識用ファイルが対応している版ではありません。ホーム画面で準備状態を確認してください。"
        case .invalidAudio:
            return "Haas に送る音声を変換できませんでした。"
        case .protocolViolation:
            return "Haas の応答を処理できませんでした。もう一度録音を開始してください。"
        case .recognition:
            return "音声の認識を完了できませんでした。もう一度録音してください。"
        case .timeout:
            return "音声認識の処理が時間内に完了しませんでした。もう一度お試しください。"
        case .audioBacklog:
            return "音声の送信が追いつかないため、Haas の認識を停止しました。録音は履歴から確認できます。"
        case .notConnected:
            return "Haas に接続していません。"
        }
    }
}
