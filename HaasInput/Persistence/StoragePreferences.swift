import Foundation

enum CleanupSettingsKeys {
    static let isTranscriptionCleanupEnabled = "IsTranscriptionCleanupEnabled"
    static let transcriptionRetentionMinutes = "TranscriptionRetentionMinutes"
    static let isAudioCleanupEnabled = "IsAudioCleanupEnabled"
    static let audioRetentionPeriod = "AudioRetentionPeriod"
    static let lastAutomaticAudioCleanupDate = "AudioCleanupLastAutomaticCleanupDate"
}

enum CleanupDefaultsMigration {
    /// 0.1.1 で履歴の自動削除を既定で有効 (7日) にした。それ以前の保存データがあり、
    /// 設定を一度も保存していない利用者は旧既定値 (無効・1日) のまま残す。
    /// 判定結果は保存し、初回起動で作られたストアを次回起動で旧版のものと誤認しないようにする。
    static func persistInitialCleanupDefaults(defaults: UserDefaults = .standard, storageDirectory: URL) {
        guard defaults.object(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled) == nil else { return }
        let hasLegacyStore = FileManager.default.fileExists(
            atPath: storageDirectory.appendingPathComponent("default.store").path)
        defaults.set(!hasLegacyStore, forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled)
        if defaults.object(forKey: CleanupSettingsKeys.transcriptionRetentionMinutes) == nil {
            defaults.set(hasLegacyStore ? 1440 : 10080, forKey: CleanupSettingsKeys.transcriptionRetentionMinutes)
        }
    }
}
