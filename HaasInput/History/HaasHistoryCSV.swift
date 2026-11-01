import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum HaasHistoryCSV {
    @MainActor
    static func export(_ rows: [Transcription]) throws {
        let panel = NSSavePanel()
        panel.title = "履歴をCSVで書き出す"
        panel.prompt = "書き出す"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Haas音声入力の履歴.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data(for: rows).write(to: url, options: .atomic)
    }

    static func data(for rows: [Transcription]) -> Data {
        var values = [["認識結果", "保存済み整形文", "整形モデル(旧データ)", "プロンプト(旧データ)", "認識モデル", "モード(旧データ)", "整形時間(秒)", "認識時間(秒)", "記録日時", "録音時間(秒)"]]
        values += rows.sorted { $0.timestamp < $1.timestamp }.map { row in
            [row.text, row.enhancedText ?? "", row.aiEnhancementModelName ?? "", row.promptName ?? "",
             row.transcriptionModelName ?? "", row.modeName ?? "", row.enhancementDuration.map { String($0) } ?? "",
             row.transcriptionDuration.map { String($0) } ?? "", row.timestamp.ISO8601Format(), String(row.duration)]
        }
        let text = values.map { row in
            row.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
        return Data(text.utf8)
    }
}
