import Foundation
import SwiftData

enum FixtureError: Error {
    case invalidArguments, pathOutsideFixture, existingStore, missingStore
}

@main
struct FixtureRunner {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              ["seed", "dump"].contains(CommandLine.arguments[1]) else { throw FixtureError.invalidArguments }
        let mode = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        let allowed = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".haas-build/dedicated-legacy-fixtures").standardizedFileURL.resolvingSymlinksInPath()
        guard root == allowed else { throw FixtureError.pathOutsideFixture }
        let stores = root.appendingPathComponent("stores", isDirectory: true)
        let storeNames = ["default", "dictionary", "stats"]
        for name in storeNames {
            let exists = FileManager.default.fileExists(atPath: stores.appendingPathComponent("\(name).store").path)
            if mode == "seed", exists { throw FixtureError.existingStore }
            if mode == "dump", !exists { throw FixtureError.missingStore }
        }
        try FileManager.default.createDirectory(at: stores, withIntermediateDirectories: true)
        let schema = Schema([Transcription.self, VocabularyWord.self, WordReplacement.self, SessionMetric.self])
        let transcriptConfig = ModelConfiguration("default", schema: Schema([Transcription.self]), url: stores.appendingPathComponent("default.store"), cloudKitDatabase: .none)
        let dictionaryConfig = ModelConfiguration("dictionary", schema: Schema([VocabularyWord.self, WordReplacement.self]), url: stores.appendingPathComponent("dictionary.store"), cloudKitDatabase: .none)
        let statsConfig = ModelConfiguration("stats", schema: Schema([SessionMetric.self]), url: stores.appendingPathComponent("stats.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig)
        let context = container.mainContext
        context.autosaveEnabled = false
        if mode == "seed" {
            let data = try Data(contentsOf: root.appendingPathComponent("expected.json"))
            let fixture = try JSONSerialization.jsonObject(with: data) as! [String: [[String: Any]]]
            for x in fixture["Transcription"]! {
                let row = Transcription(text: x["text"] as! String, duration: number(x, "duration"))
                row.id = uuid(x, "id")
                row.enhancedText = x["enhancedText"] as? String
                row.timestamp = Date(timeIntervalSince1970: number(x, "timestamp"))
                row.audioFileURL = x["audioFileURL"] as? String
                row.transcriptionModelName = x["transcriptionModelName"] as? String
                row.aiEnhancementModelName = x["aiEnhancementModelName"] as? String
                row.promptName = x["promptName"] as? String
                row.transcriptionDuration = (x["transcriptionDuration"] as? NSNumber)?.doubleValue
                row.enhancementDuration = (x["enhancementDuration"] as? NSNumber)?.doubleValue
                row.aiRequestSystemMessage = x["aiRequestSystemMessage"] as? String
                row.aiRequestUserMessage = x["aiRequestUserMessage"] as? String
                row.modeName = x["modeName"] as? String
                row.modeEmoji = x["modeEmoji"] as? String
                row.transcriptionStatus = x["transcriptionStatus"] as? String
                context.insert(row)
            }
            for x in fixture["VocabularyWord"]! {
                context.insert(VocabularyWord(word: x["word"] as! String, dateAdded: Date(timeIntervalSince1970: number(x, "dateAdded"))))
            }
            for x in fixture["WordReplacement"]! {
                let row = WordReplacement(originalText: x["originalText"] as! String, replacementText: x["replacementText"] as! String, dateAdded: Date(timeIntervalSince1970: number(x, "dateAdded")))
                row.id = uuid(x, "id")
                row.isEnabled = x["isEnabled"] as! Bool
                context.insert(row)
            }
            for x in fixture["SessionMetric"]! {
                let row = SessionMetric(transcriptionId: uuid(x, "transcriptionId"), timestamp: Date(timeIntervalSince1970: number(x, "timestamp")), source: x["source"] as? String, wordCount: (x["wordCount"] as! NSNumber).intValue, audioDuration: number(x, "audioDuration"), transcriptionModelName: x["transcriptionModelName"] as? String, transcriptionDuration: (x["transcriptionDuration"] as? NSNumber)?.doubleValue, speedFactor: (x["speedFactor"] as? NSNumber)?.doubleValue, modeName: x["modeName"] as? String, aiEnhancementModelName: x["aiEnhancementModelName"] as? String, enhancementDuration: (x["enhancementDuration"] as? NSNumber)?.doubleValue, enhancementEstimatedTokenCount: (x["enhancementEstimatedTokenCount"] as? NSNumber)?.intValue)
                row.id = uuid(x, "id")
                context.insert(row)
            }
            try context.save()
            print("Seeded synthetic legacy stores: Transcription=3 VocabularyWord=2 WordReplacement=2 SessionMetric=2")
        } else {
            let result: [String: Any] = [
                "Transcription": try context.fetch(FetchDescriptor<Transcription>()).sorted { $0.id.uuidString < $1.id.uuidString }.map { row -> [String: Any] in
                    ["id": row.id.uuidString, "text": row.text, "enhancedText": optional(row.enhancedText), "timestamp": row.timestamp.timeIntervalSince1970, "duration": row.duration, "audioFileURL": optional(row.audioFileURL), "transcriptionModelName": optional(row.transcriptionModelName), "aiEnhancementModelName": optional(row.aiEnhancementModelName), "promptName": optional(row.promptName), "transcriptionDuration": optional(row.transcriptionDuration), "enhancementDuration": optional(row.enhancementDuration), "aiRequestSystemMessage": optional(row.aiRequestSystemMessage), "aiRequestUserMessage": optional(row.aiRequestUserMessage), "modeName": optional(row.modeName), "modeEmoji": optional(row.modeEmoji), "transcriptionStatus": optional(row.transcriptionStatus)]
                },
                "VocabularyWord": try context.fetch(FetchDescriptor<VocabularyWord>()).sorted { $0.word < $1.word }.map { row -> [String: Any] in
                    ["word": row.word, "dateAdded": row.dateAdded.timeIntervalSince1970]
                },
                "WordReplacement": try context.fetch(FetchDescriptor<WordReplacement>()).sorted { $0.id.uuidString < $1.id.uuidString }.map { row -> [String: Any] in
                    ["id": row.id.uuidString, "originalText": row.originalText, "replacementText": row.replacementText, "dateAdded": row.dateAdded.timeIntervalSince1970, "isEnabled": row.isEnabled]
                },
                "SessionMetric": try context.fetch(FetchDescriptor<SessionMetric>()).sorted { $0.id.uuidString < $1.id.uuidString }.map { row -> [String: Any] in
                    ["id": row.id.uuidString, "transcriptionId": row.transcriptionId.uuidString, "timestamp": row.timestamp.timeIntervalSince1970, "source": optional(row.source), "wordCount": row.wordCount, "audioDuration": row.audioDuration, "transcriptionModelName": optional(row.transcriptionModelName), "transcriptionDuration": optional(row.transcriptionDuration), "speedFactor": optional(row.speedFactor), "modeName": optional(row.modeName), "aiEnhancementModelName": optional(row.aiEnhancementModelName), "enhancementDuration": optional(row.enhancementDuration), "enhancementEstimatedTokenCount": optional(row.enhancementEstimatedTokenCount)]
                }
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: root.appendingPathComponent("observed-old.json"), options: .atomic)
            print("Dumped persisted legacy values")
        }
    }
    private static func number(_ row: [String: Any], _ key: String) -> Double { (row[key] as! NSNumber).doubleValue }
    private static func uuid(_ row: [String: Any], _ key: String) -> UUID { UUID(uuidString: row[key] as! String)! }
    private static func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
}
