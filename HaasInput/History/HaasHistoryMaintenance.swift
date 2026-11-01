import Foundation
import SwiftData
import os

@MainActor
final class HaasHistoryMaintenance {
    static let shared = HaasHistoryMaintenance()

    private let defaults: UserDefaults
    private let recordingsDirectory: URL
    private let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "HistoryMaintenance")

    init(defaults: UserDefaults = .standard, recordingsDirectory: URL? = nil) {
        self.defaults = defaults
        self.recordingsDirectory = (recordingsDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppStorageIdentity.applicationSupportDirectoryName)
            .appendingPathComponent("Recordings", isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
    }

    @discardableResult
    func run(context: ModelContext, activeAudioURL: URL? = nil) throws -> Int {
        guard !context.hasChanges else { throw HaasHistoryError.unsavedChanges }
        let removesHistory = defaults.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled)
        let removesAudio = defaults.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled)
        guard removesHistory || removesAudio else { return 0 }
        let now = Date()
        if !removesHistory,
           let last = defaults.object(forKey: CleanupSettingsKeys.lastAutomaticAudioCleanupDate) as? Date,
           now.timeIntervalSince(last) < 86_400 { return 0 }
        let rows = try context.fetch(FetchDescriptor<Transcription>())
        let seconds = removesHistory
            ? Double(max(0, defaults.integer(forKey: CleanupSettingsKeys.transcriptionRetentionMinutes))) * 60
            : Double(max(0, defaults.integer(forKey: CleanupSettingsKeys.audioRetentionPeriod))) * 86_400
        let cutoff = now.addingTimeInterval(-Double(seconds))
        let expired = rows.filter {
            $0.timestamp < cutoff && $0.transcriptionStatus != TranscriptionStatus.pending.rawValue
                && !isProtected($0, activeAudioURL: activeAudioURL)
                && (removesHistory || $0.audioFileURL != nil)
        }
        try change(expired, allRows: rows, removingHistory: removesHistory, context: context, activeAudioURL: activeAudioURL)
        if !removesHistory { defaults.set(now, forKey: CleanupSettingsKeys.lastAutomaticAudioCleanupDate) }
        return expired.count
    }

    func delete(_ rows: [Transcription], context: ModelContext, activeAudioURL: URL? = nil) throws {
        guard !context.hasChanges else { throw HaasHistoryError.unsavedChanges }
        guard !rows.contains(where: { isProtected($0, activeAudioURL: activeAudioURL) }) else {
            throw HaasHistoryError.recordingInProgress
        }
        let allRows = try context.fetch(FetchDescriptor<Transcription>())
        try change(rows, allRows: allRows, removingHistory: true, context: context, activeAudioURL: activeAudioURL)
    }

    private func isProtected(_ row: Transcription, activeAudioURL: URL?) -> Bool {
        guard let activeAudioURL, let text = row.audioFileURL, let url = URL(string: text) else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath() == activeAudioURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func change(
        _ rows: [Transcription], allRows: [Transcription], removingHistory: Bool,
        context: ModelContext, activeAudioURL: URL?
    ) throws {
        guard !rows.isEmpty else { return }
        let ids = Set(rows.map(\.id))
        let retainedFiles = Set(allRows.filter { !ids.contains($0.id) }.compactMap { ownedAudioURL($0.audioFileURL) })
        let activeFile = activeAudioURL?.standardizedFileURL.resolvingSymlinksInPath()
        let files = Set(rows.compactMap { ownedAudioURL($0.audioFileURL) })
            .subtracting(retainedFiles).filter { $0 != activeFile }
        var moved: [(original: URL, trashed: URL)] = []
        do {
            for file in files where FileManager.default.fileExists(atPath: file.path) {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw HaasHistoryError.audioUnavailable }
                var trashed: NSURL?
                try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
                if let trashed { moved.append((file, trashed as URL)) }
            }
            for row in rows {
                if removingHistory { context.delete(row) }
                else { row.audioFileURL = nil }
            }
            try context.save()
        } catch {
            context.rollback()
            var couldRestore = true
            for item in moved.reversed() {
                do { try FileManager.default.moveItem(at: item.trashed, to: item.original) }
                catch {
                    couldRestore = false
                    logger.error("Audio rollback failed: \(String(describing: error), privacy: .private)")
                }
            }
            logger.error("History cleanup failed: \(String(describing: error), privacy: .private)")
            throw couldRestore ? HaasHistoryError.saveFailed : HaasHistoryError.audioRestoreFailed
        }
    }

    private func ownedAudioURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.isFileURL else { return nil }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(recordingsDirectory.path + "/") else { return nil }
        return resolved
    }
}

enum HaasHistoryError: LocalizedError {
    case unsavedChanges, recordingInProgress, audioUnavailable, saveFailed, audioRestoreFailed

    var errorDescription: String? {
        switch self {
        case .unsavedChanges:
            return "保存できていない変更があります。ホームで履歴の保存を再試行してから操作してください。"
        case .recordingInProgress:
            return "録音中の履歴は削除できません。録音を停止してからもう一度操作してください。"
        case .audioUnavailable:
            return "録音ファイルを確認できませんでした。履歴は削除していません。"
        case .saveFailed:
            return "履歴の変更を保存できませんでした。削除を取り消しました。"
        case .audioRestoreFailed:
            return "履歴の変更を保存できず、一部の録音ファイルを元へ戻せませんでした。ゴミ箱を確認してください。"
        }
    }
}
