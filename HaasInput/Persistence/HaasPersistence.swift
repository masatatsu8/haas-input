import Foundation
import SwiftData

@MainActor
final class HaasPersistence {
    let container: ModelContainer
    var mainContext: ModelContext { container.mainContext }

    init(directory: URL? = nil) throws {
        let directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppStorageIdentity.applicationSupportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let schema = Schema([Transcription.self, VocabularyWord.self, WordReplacement.self, SessionMetric.self])
        let transcript = ModelConfiguration(
            "default", schema: Schema([Transcription.self]),
            url: directory.appendingPathComponent("default.store"), cloudKitDatabase: .none
        )
        let dictionary = ModelConfiguration(
            "dictionary", schema: Schema([VocabularyWord.self, WordReplacement.self]),
            url: directory.appendingPathComponent("dictionary.store"), cloudKitDatabase: .none
        )
        let stats = ModelConfiguration(
            "stats", schema: Schema([SessionMetric.self]),
            url: directory.appendingPathComponent("stats.store"), cloudKitDatabase: .none
        )
        container = try ModelContainer(for: schema, configurations: transcript, dictionary, stats)
        container.mainContext.autosaveEnabled = false
    }
}
