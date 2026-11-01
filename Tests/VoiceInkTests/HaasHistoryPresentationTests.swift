import XCTest
@testable import VoiceInk

final class HaasHistoryPresentationTests: XCTestCase {
    func testHistoryTextKeepsRecognizedContentAndLocalizesCancellationPlaceholders() {
        for scenario in HistoryPresentationCases.all {
            let transcription = Transcription(
                text: scenario.text, duration: 1,
                enhancedText: scenario.enhancedText, transcriptionStatus: scenario.status
            )
            XCTAssertEqual(transcription.preferredHistoryText, scenario.expected, scenario.name)
        }
    }
}

private enum HistoryPresentationCases {
    struct Scenario {
        let name: String
        let status: TranscriptionStatus
        let text: String
        let enhancedText: String?
        let expected: String
    }

    static let all: [Scenario] = [
        .init(name: "cancelled recognized text", status: .canceled,
              text: "途中まで認識した文章", enhancedText: nil, expected: "途中まで認識した文章"),
        .init(name: "cancelled text preserves spacing", status: .canceled,
              text: "  途中の文章\n", enhancedText: nil, expected: "  途中の文章\n"),
        .init(name: "cancelled legacy enhancement retained", status: .canceled,
              text: "今回の認識済み本文", enhancedText: "以前の整形結果", expected: "以前の整形結果"),
        .init(name: "legacy cancellation placeholder", status: .canceled,
              text: "The transcription was canceled.", enhancedText: nil, expected: "文字起こしを取り消しました。"),
        .init(name: "empty cancellation", status: .canceled,
              text: "", enhancedText: nil, expected: "文字起こしを取り消しました。"),
        .init(name: "whitespace cancellation", status: .canceled,
              text: " \n", enhancedText: nil, expected: "文字起こしを取り消しました。"),
        .init(name: "Japanese cancellation placeholder", status: .canceled,
              text: "文字起こしを取り消しました。", enhancedText: nil, expected: "文字起こしを取り消しました。"),
        .init(name: "completed enhancement", status: .completed,
              text: "認識した本文", enhancedText: "整えた本文", expected: "整えた本文"),
        .init(name: "enhancement keeps original whitespace", status: .completed,
              text: "認識した本文", enhancedText: "  整えた本文\n", expected: "  整えた本文\n"),
        .init(name: "completed raw text", status: .completed,
              text: "認識した本文", enhancedText: nil, expected: "認識した本文"),
        .init(name: "blank enhancement", status: .completed,
              text: "認識した本文", enhancedText: " \n", expected: "認識した本文"),
        .init(name: "English enhancement failure", status: .completed,
              text: "認識した本文", enhancedText: "  Enhancement failed: fixture error", expected: "認識した本文"),
        .init(name: "German enhancement failure", status: .completed,
              text: "認識した本文", enhancedText: "Verbesserung fehlgeschlagen: fixture error", expected: "認識した本文"),
        .init(name: "French enhancement failure", status: .completed,
              text: "認識した本文", enhancedText: "Échec de l'amélioration : fixture error", expected: "認識した本文"),
        .init(name: "Chinese enhancement failure", status: .completed,
              text: "認識した本文", enhancedText: "润色失败：fixture error", expected: "認識した本文"),
    ]
}
