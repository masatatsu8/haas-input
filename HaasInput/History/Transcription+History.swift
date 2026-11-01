import Foundation

extension Transcription {
    var preferredHistoryText: String {
        var preferred = text
        if let enhancedText, !enhancedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let prefixes = ["enhancement failed:", "verbesserung fehlgeschlagen:", "échec de l'amélioration :", "润色失败："]
            let trimmed = enhancedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefixes.contains(where: { trimmed.lowercased().hasPrefix($0.lowercased()) }) {
                preferred = enhancedText
            }
        }
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if transcriptionStatus == TranscriptionStatus.canceled.rawValue,
            trimmed.isEmpty || trimmed == "The transcription was canceled."
        {
            return Transcription.canceledTranscriptionText
        }
        return preferred
    }

    var availableHistoryAudioURL: URL? {
        guard let audioFileURL, let url = URL(string: audioFileURL), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var historyStatusLabel: String {
        switch transcriptionStatus {
        case TranscriptionStatus.pending.rawValue: "処理中"
        case TranscriptionStatus.completed.rawValue: "完了"
        case TranscriptionStatus.failed.rawValue: "失敗"
        case TranscriptionStatus.canceled.rawValue: "取消"
        default: "過去の履歴"
        }
    }
}
