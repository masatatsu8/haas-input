import Foundation
import SwiftData

@MainActor
final class WordReplacementService {
    static let shared = WordReplacementService()

    private var cachedRecords: [WordReplacementPlan.Record]?
    private var cachedPlan: WordReplacementPlan?

    private init() {}

    func snapshot(using context: ModelContext) throws -> WordReplacementPlan {
        // The persisted isEnabled field is retained for CloudKit compatibility; every explicit rule remains active.
        let replacements = try context.fetch(FetchDescriptor<WordReplacement>())
        let records = replacements.map {
            WordReplacementPlan.Record(
                id: $0.id,
                originalText: $0.originalText,
                replacementText: $0.replacementText,
                dateAdded: $0.dateAdded
            )
        }.sorted { $0.id.uuidString < $1.id.uuidString }

        if cachedRecords == records, let cachedPlan {
            return cachedPlan
        }
        let plan = try WordReplacementPlan(records: records)
        cachedRecords = records
        cachedPlan = plan
        return plan
    }
}
