import AppKit
import Foundation

enum RecorderDisplaySettingsKeys {
    static let showLiveTranscript = "ShowLiveTranscript"
}

enum HaasAppConfiguration {
    static let name = "Haas音声入力"
    static let mainWindowID = "haas-main"

    static func prepare() {
        UserDefaults.standard.register(defaults: [
            "clipboardRestoreDelay": 2.0,
            "isSystemMuteEnabled": true,
            "audioResumptionDelay": 0.0,
            "isPauseMediaEnabled": false,
            "RecorderType": "mini",
            RecorderDisplaySettingsKeys.showLiveTranscript: true,
            CleanupSettingsKeys.isTranscriptionCleanupEnabled: false,
            CleanupSettingsKeys.transcriptionRetentionMinutes: 1440,
            CleanupSettingsKeys.isAudioCleanupEnabled: false,
            CleanupSettingsKeys.audioRetentionPeriod: 7,
            AppAppearancePreference.userDefaultsKey: AppAppearancePreference.system.rawValue,
        ])
        UserDefaults.standard.set(["ja"], forKey: "AppleLanguages")
        AppAppearancePreference.applyStored()
    }
}

enum HaasDestination: String, CaseIterable, Identifiable {
    case home, history, dictionary, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "ホーム"
        case .history: "履歴"
        case .dictionary: "辞書"
        case .settings: "設定"
        }
    }

    var symbol: String {
        switch self {
        case .home: "mic.fill"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "text.book.closed"
        case .settings: "gearshape"
        }
    }
}
