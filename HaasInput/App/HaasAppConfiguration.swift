import AppKit
import Foundation

enum RecorderDisplaySettingsKeys {
    static let showLiveTranscript = "ShowLiveTranscript"
}

enum HaasAppConfiguration {
    static let name = "Haas音声入力"
    static let mainWindowID = "haas-main"

    static func prepare() {
        CleanupDefaultsMigration.persistInitialCleanupDefaults(storageDirectory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppStorageIdentity.applicationSupportDirectoryName, isDirectory: true))
        UserDefaults.standard.register(defaults: [
            "clipboardRestoreDelay": 0.5,
            "isSystemMuteEnabled": true,
            "audioResumptionDelay": 0.0,
            "isPauseMediaEnabled": false,
            "RecorderType": "mini",
            RecorderDisplaySettingsKeys.showLiveTranscript: true,
            CleanupSettingsKeys.isTranscriptionCleanupEnabled: true,
            CleanupSettingsKeys.transcriptionRetentionMinutes: 10080,
            CleanupSettingsKeys.isAudioCleanupEnabled: false,
            CleanupSettingsKeys.audioRetentionPeriod: 7,
            AppAppearancePreference.userDefaultsKey: AppAppearancePreference.system.rawValue,
        ])
        UserDefaults.standard.set(["ja"], forKey: "AppleLanguages")
        AppAppearancePreference.applyStored()
    }
}

enum HaasDestination: String, CaseIterable, Identifiable {
    case home, usage, history, dictionary, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "ホーム"
        case .usage: "記録"
        case .history: "履歴"
        case .dictionary: "辞書"
        case .settings: "設定"
        }
    }

    var symbol: String {
        switch self {
        case .home: "mic.fill"
        case .usage: "leaf.fill"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "text.book.closed"
        case .settings: "gearshape"
        }
    }
}
