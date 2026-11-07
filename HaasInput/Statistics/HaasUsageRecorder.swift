import Foundation
import os
import SwiftData

/// 録音ごとの利用記録を、本文なしで統計専用の保存先へ残す。
/// 履歴(Transcription)が消えても統計は残る。
@MainActor
final class HaasUsageRecorder: ObservableObject {
    /// 新しい数え方の記録を示す source。旧アプリ由来の SessionMetric とは区別する。
    static let source = "haas-usage"

    @Published private(set) var samples: [HaasUsageSample] = []

    private let context: ModelContext
    private let save: (ModelContext) throws -> Void
    private let fetchMetrics: (ModelContext) throws -> [SessionMetric]
    /// 前回の保存に失敗して、まだ統計に入っていない分
    private var pending: [UUID: HaasUsageSample] = [:]
    private let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "UsageRecorder")

    init(
        container: ModelContainer,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        fetchMetrics: @escaping (ModelContext) throws -> [SessionMetric] = HaasUsageRecorder.fetchStoredMetrics
    ) {
        context = ModelContext(container)
        context.autosaveEnabled = false
        self.save = save
        self.fetchMetrics = fetchMetrics
    }

    /// 履歴 (保存済みの行だけ) を読み、統計にない分を書き足して `samples` を更新する。
    func sync(from history: ModelContext) {
        var descriptor = FetchDescriptor<Transcription>()
        descriptor.includePendingChanges = false
        let completed = TranscriptionStatus.completed.rawValue
        let rows: [Transcription]
        do {
            rows = try history.fetch(descriptor)
        } catch {
            logger.error("履歴の読み込みに失敗: \(error.localizedDescription, privacy: .private)")
            return
        }

        // 統計の読み込みに失敗したら、重複して挿入しないよう何も書かずに戻る。
        // 履歴はこの後に消えうるので、対象の行は値にして保留し、次の同期で入れ直す
        var known: Set<UUID>
        do {
            known = Set(try storedMetrics().map(\.transcriptionId))
        } catch {
            logger.error("利用記録の読み込みに失敗: \(error.localizedDescription, privacy: .private)")
            for row in rows where row.transcriptionStatus == completed {
                let characters = HaasUsageSample.characterCount(row.text)
                guard characters > 0, pending[row.id] == nil else { continue }
                pending[row.id] = HaasUsageSample(
                    timestamp: row.timestamp, duration: row.duration, characters: characters
                )
            }
            return
        }
        var attempted: [UUID: HaasUsageSample] = [:]

        func insert(id: UUID, sample: HaasUsageSample) {
            guard !known.contains(id) else { return }
            known.insert(id)
            attempted[id] = sample
            context.insert(SessionMetric(
                transcriptionId: id, timestamp: sample.timestamp, source: Self.source,
                wordCount: sample.characters, audioDuration: sample.duration,
                transcriptionModelName: nil, transcriptionDuration: nil, speedFactor: nil,
                modeName: nil, aiEnhancementModelName: nil, enhancementDuration: nil
            ))
        }

        for row in rows where row.transcriptionStatus == completed {
            let characters = HaasUsageSample.characterCount(row.text)
            guard characters > 0 else { continue }
            insert(id: row.id, sample: HaasUsageSample(
                timestamp: row.timestamp, duration: row.duration, characters: characters
            ))
        }
        for (id, sample) in pending { insert(id: id, sample: sample) }

        do {
            try save(context)
            pending = [:]
        } catch {
            context.rollback()
            for (id, sample) in attempted { pending[id] = sample }
            logger.error("利用記録の保存に失敗: \(error.localizedDescription, privacy: .private)")
        }

        refreshSamples()
    }

    private func storedMetrics() throws -> [SessionMetric] {
        try fetchMetrics(context)
    }

    private static func fetchStoredMetrics(_ context: ModelContext) throws -> [SessionMetric] {
        let source = Self.source
        return try context.fetch(FetchDescriptor<SessionMetric>(
            predicate: #Predicate { $0.source == source }
        ))
    }

    private func refreshSamples() {
        let stored: [SessionMetric]
        do {
            stored = try storedMetrics()
        } catch {
            // 読めないときは前回の samples を保つ
            logger.error("利用記録の読み込みに失敗: \(error.localizedDescription, privacy: .private)")
            return
        }
        var byId: [UUID: HaasUsageSample] = [:]
        for metric in stored {
            byId[metric.transcriptionId] = HaasUsageSample(
                timestamp: metric.timestamp, duration: metric.audioDuration, characters: metric.wordCount
            )
        }
        for (id, sample) in pending where byId[id] == nil { byId[id] = sample }
        samples = byId.sorted {
            $0.value.timestamp == $1.value.timestamp
                ? $0.key.uuidString < $1.key.uuidString
                : $0.value.timestamp < $1.value.timestamp
        }.map(\.value)
    }
}
