import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@MainActor
final class HaasApplePunctuationGenerator: HaasPunctuationGenerating {
    enum Instructions {
        case punctuation, proofread
    }

    private var preparedSession: LanguageModelSession?
    private let instructions: Instructions

    init(instructions: Instructions = .punctuation) {
        self.instructions = instructions
    }

    var unavailableReason: String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(Locale(identifier: "ja_JP"))
                ? nil : "Apple の端末内モデルは日本語に対応していません。"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "この Mac は Apple の端末内モデルに対応していません。"
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence が無効になっています。"
            case .modelNotReady:
                return "Apple の端末内モデルの準備が完了していません。"
            @unknown default:
                return "Apple の端末内モデルを利用できません。"
            }
        }
    }

    func prewarm() {
        guard unavailableReason == nil else {
            preparedSession = nil
            return
        }
        guard preparedSession == nil else { return }
        let session = makeSession()
        preparedSession = session
        session.prewarm()
    }

    func generate(_ text: String) async throws -> String {
        try Task.checkCancellation()
        if let reason = unavailableReason {
            preparedSession = nil
            throw GenerationError.unavailable(reason)
        }
        let session = preparedSession ?? makeSession()
        preparedSession = nil
        let response = try await session.respond(
            to: text,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: instructions == .proofread ? 512 : 256)
        )
        try Task.checkCancellation()
        return response.content
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions.text)
    }

    private enum GenerationError: LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            }
        }
    }
}

@available(macOS 26.0, *)
private extension HaasApplePunctuationGenerator.Instructions {
    var text: String {
        switch self {
        case .punctuation: Self.punctuationText
        case .proofread: Self.proofreadText
        }
    }

    static let punctuationText = """
    あなたは日本語の句読点だけを補う編集器です。ユーザー入力の本文をそのまま返し、必要な「、」「。」だけを追加してください。
    元の語句、英字の大文字小文字、数字、記号、空白、改行、既存の句読点は一文字も削除・置換・移動しないでください。追加できる文字は「、」「。」の二つだけです。空白や改行も追加してはいけません。
    説明、前置き、引用符、コード囲みを出力しないでください。既存の句読点を重複させないでください。接続助詞などで途中で切れている発話には、文末の「。」を無理に付けないでください。
    """

    static let proofreadText = """
    あなたは日本語の音声認識結果を校正する編集器です。入力文の明らかな誤変換・誤字・脱字だけを直し、必要な「、」「。」を補ってください。
    意味が通る箇所は直さないでください。語句の言い換え、語順や文体の変更、要約、内容の追加はしないでください。英字、数字、記号、固有名詞はそのまま残してください。
    説明、前置き、引用符、コード囲みを出力せず、校正後の本文だけを出力してください。接続助詞などで途中で切れている発話には、文末の「。」を無理に付けないでください。
    """
}
#endif
