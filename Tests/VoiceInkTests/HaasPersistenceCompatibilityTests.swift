import Foundation
import SwiftData
import XCTest
@testable import VoiceInk

@MainActor
final class HaasPersistenceCompatibilityTests: XCTestCase {
    func testLegacyStoresKeepEverySavedAttributeAndRemainWritable() throws {
        let resources = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
            .appendingPathComponent("Fixtures/LegacyHaas", isDirectory: true)
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: resources.appendingPathComponent("expected.json"))
        ) as? [String: Any])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaasLegacyCompatibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: resources.appendingPathComponent("stores"), to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let appendedID = UUID()
        do {
            let persistence = try HaasPersistence(directory: directory)
            XCTAssertEqual(try snapshot(persistence.mainContext) as NSDictionary, expected as NSDictionary)
            let added = Transcription(text: "新しい専用版で保存した文", duration: 2)
            added.id = appendedID
            persistence.mainContext.insert(added)
            try persistence.mainContext.save()
        }

        let reopened = try HaasPersistence(directory: directory)
        let transcripts = try reopened.mainContext.fetch(FetchDescriptor<Transcription>())
        XCTAssertEqual(transcripts.first { $0.id == appendedID }?.text, "新しい専用版で保存した文")
        XCTAssertEqual(transcripts.count, 4)
        XCTAssertEqual(
            try snapshot(reopened.mainContext, excludingTranscription: appendedID) as NSDictionary,
            expected as NSDictionary,
            "Opening and saving with the dedicated app must not rewrite or discard legacy values"
        )
    }

    private func value<T>(_ optional: T?) -> Any { optional.map { $0 as Any } ?? NSNull() }

    private func snapshot(_ context: ModelContext, excludingTranscription: UUID? = nil) throws -> [String: Any] {
        let transcripts = try context.fetch(FetchDescriptor<Transcription>())
            .filter { $0.id != excludingTranscription }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let vocabulary = try context.fetch(FetchDescriptor<VocabularyWord>()).sorted { $0.word < $1.word }
        let replacements = try context.fetch(FetchDescriptor<WordReplacement>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let metrics = try context.fetch(FetchDescriptor<SessionMetric>()).sorted { $0.id.uuidString < $1.id.uuidString }
        return [
            "Transcription": transcripts.map { row -> [String: Any] in
                [
                    "id": row.id.uuidString, "text": row.text, "enhancedText": value(row.enhancedText),
                    "timestamp": row.timestamp.timeIntervalSince1970, "duration": row.duration,
                    "audioFileURL": value(row.audioFileURL), "transcriptionModelName": value(row.transcriptionModelName),
                    "aiEnhancementModelName": value(row.aiEnhancementModelName), "promptName": value(row.promptName),
                    "transcriptionDuration": value(row.transcriptionDuration), "enhancementDuration": value(row.enhancementDuration),
                    "aiRequestSystemMessage": value(row.aiRequestSystemMessage), "aiRequestUserMessage": value(row.aiRequestUserMessage),
                    "modeName": value(row.modeName), "modeEmoji": value(row.modeEmoji),
                    "transcriptionStatus": value(row.transcriptionStatus),
                ]
            },
            "VocabularyWord": vocabulary.map { row -> [String: Any] in
                ["word": row.word, "dateAdded": row.dateAdded.timeIntervalSince1970]
            },
            "WordReplacement": replacements.map { row -> [String: Any] in
                [
                    "id": row.id.uuidString, "originalText": row.originalText, "replacementText": row.replacementText,
                    "dateAdded": row.dateAdded.timeIntervalSince1970, "isEnabled": row.isEnabled,
                ]
            },
            "SessionMetric": metrics.map { row -> [String: Any] in
                [
                    "id": row.id.uuidString, "transcriptionId": row.transcriptionId.uuidString,
                    "timestamp": row.timestamp.timeIntervalSince1970, "source": value(row.source),
                    "wordCount": row.wordCount, "audioDuration": row.audioDuration,
                    "transcriptionModelName": value(row.transcriptionModelName),
                    "transcriptionDuration": value(row.transcriptionDuration), "speedFactor": value(row.speedFactor),
                    "modeName": value(row.modeName), "aiEnhancementModelName": value(row.aiEnhancementModelName),
                    "enhancementDuration": value(row.enhancementDuration),
                    "enhancementEstimatedTokenCount": value(row.enhancementEstimatedTokenCount),
                ]
            },
        ]
    }
}
