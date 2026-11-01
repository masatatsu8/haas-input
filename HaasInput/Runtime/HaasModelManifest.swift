import Foundation

struct HaasRuntimeSelection: Equatable, Sendable {
    let executablePath: String
    let modelPath: String
    let vadModelPath: String
}

struct HaasModelPreparationProgress: Equatable, Sendable {
    enum Phase: Sendable { case checking, downloading, verifying }
    let phase: Phase
    var assetName: String? = nil
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
}

struct HaasModelAsset: Equatable, Sendable {
    enum Kind: CaseIterable, Hashable, Sendable {
        case recognition, vad
        var filename: String {
            switch self {
            case .recognition: return HaasRuntimeConfiguration.modelFilename
            case .vad: return HaasRuntimeConfiguration.vadFilename
            }
        }
        var displayName: String {
            switch self {
            case .recognition: return "Haas-ja Q8"
            case .vad: return "Silero VAD"
            }
        }
    }

    let kind: Kind
    let sourceURL: URL
    let sha256: String
    let byteCount: Int64
    let revision: String
    var filename: String { kind.filename }
    var displayName: String { kind.displayName }
}

struct HaasModelManifest: Sendable {
    let assets: [HaasModelAsset]

    init(contentsOf url: URL) throws {
        struct Manifest: Decodable {
            struct Source: Decodable { let url: URL; let sha256: String }
            struct File: Decodable { let sha256: String; let size: Int64 }
            let model_revision: String
            let vad_revision: String
            let model_layout: Int
            let model_quantization: String
            let sources: [String: Source]
            let files: [String: File]
        }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > 0, size <= 131_072
        else { throw HaasModelDownloadError.invalidManifest }
        let decoded: Manifest
        do { decoded = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)) }
        catch { throw HaasModelDownloadError.invalidManifest }
        guard decoded.model_layout == 4, decoded.model_quantization == "Q8_0" else {
            throw HaasModelDownloadError.invalidManifest
        }
        assets = try HaasModelAsset.Kind.allCases.map { kind in
            let revision = kind == .recognition ? decoded.model_revision : decoded.vad_revision
            guard let source = decoded.sources[kind.filename], let file = decoded.files[kind.filename],
                source.url.scheme == "https", source.url.host == "huggingface.co",
                source.url.user == nil, source.url.password == nil,
                revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
                source.url.path.contains("/resolve/\(revision)/"),
                file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                source.sha256 == file.sha256, file.size > 0, file.size <= 10_000_000_000
            else { throw HaasModelDownloadError.invalidManifest }
            return HaasModelAsset(
                kind: kind, sourceURL: source.url, sha256: file.sha256,
                byteCount: file.size, revision: revision)
        }
    }
}

enum HaasModelDownloadError: LocalizedError, Sendable {
    case invalidManifest
    case missingModel(String)
    case invalidSize(String)
    case invalidChecksum(String)
    case insecureRedirect
    case httpStatus(Int)
    case changedDuringVerification
    case unsafeCachePath(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "モデル取得情報が見つからないか、正しくありません。配布されたアプリを確認してください。"
        case .missingModel(let name): return "\(name) の準備が必要です。"
        case .invalidSize(let name): return "\(name) のファイルサイズが一致しません。もう一度ダウンロードしてください。"
        case .invalidChecksum(let name): return "\(name) の検証に失敗しました。もう一度ダウンロードしてください。"
        case .insecureRedirect: return "安全なダウンロード先を確認できませんでした。"
        case .httpStatus(let status): return "モデルを取得できませんでした (HTTP \(status))。時間をおいて再試行してください。"
        case .changedDuringVerification: return "確認中にモデルファイルが変更されました。もう一度確認してください。"
        case .unsafeCachePath(let path): return "モデル保存先にリンクまたは通常と異なるファイルがあります。保存先を確認してください: \(path)"
        }
    }
}
