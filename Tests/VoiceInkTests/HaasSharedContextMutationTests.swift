import Foundation
import SwiftData
import XCTest
@testable import VoiceInk

enum SharedContextMutation: String, CaseIterable {
    case historyDelete, replacementUpdate, replacementRemove, replacementMerge
}

struct SharedContextObservation: Codable {
    let operation: String
    let saveFailureDomain: String
    let saveFailureCode: Int
    let pendingPresent: Bool
    let pendingText: String?
    let hasChanges: Bool
    let existingHistoryPresent: Bool
    let existingHistoryText: String?
    let replacementCount: Int
    let originalText: String?
    let replacementText: String?
    let rejected: Bool
    let rejectionMessage: String?

    var violations: [String] {
        var failures: [String] = []
        if !rejected { failures.append("mutation was not refused") }
        if !pendingPresent || pendingText != "Unsaved recognition awaiting storage" {
            failures.append("unrelated unsaved transcription was lost or changed")
        }
        if !hasChanges { failures.append("pending context changes were discarded") }
        if !existingHistoryPresent || existingHistoryText != "Previously saved history" {
            failures.append("existing history was changed")
        }
        if replacementCount != 1 || originalText != "source-a" || replacementText != "Target" {
            failures.append("existing replacement was changed")
        }
        return failures
    }
}

@MainActor
enum SharedContextRegressionCases {
    struct FixtureFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(_ operation: SharedContextMutation, directory: URL) throws -> SharedContextObservation {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identifiers = try autoreleasepool { () throws -> (UUID, UUID) in
            let container = try makeContainer(directory: directory, allowsSave: true)
            let context = container.mainContext
            context.autosaveEnabled = false
            let history = Transcription(text: "Previously saved history", duration: 1, audioFileURL: nil,
                                        transcriptionStatus: .completed)
            let replacement = WordReplacement(originalText: "source-a", replacementText: "Target")
            context.insert(history)
            context.insert(replacement)
            try context.save()
            guard !context.hasChanges else { throw FixtureFailure(description: "seed save did not commit") }
            return (history.id, replacement.id)
        }

        return try autoreleasepool {
            let container = try makeContainer(directory: directory, allowsSave: false)
            guard container.configurations.allSatisfy({ !$0.allowsSave }) else {
                throw FixtureFailure(description: "fixture was not opened read-only")
            }
            let context = container.mainContext
            context.autosaveEnabled = false
            guard let history = try context.fetch(FetchDescriptor<Transcription>()).first(where: { $0.id == identifiers.0 }),
                  let replacement = try context.fetch(FetchDescriptor<WordReplacement>()).first(where: { $0.id == identifiers.1 }),
                  !context.hasChanges else {
                throw FixtureFailure(description: "persisted seed was not reloaded cleanly")
            }
            let pending = Transcription(text: "Unsaved recognition awaiting storage", duration: 2, audioFileURL: nil,
                                        transcriptionStatus: .completed)
            let pendingID = pending.id
            context.insert(pending)
            let saveFailure: NSError
            do {
                try context.save()
                throw FixtureFailure(description: "allowsSave=false unexpectedly saved the inserted transcription")
            } catch let error as FixtureFailure {
                throw error
            } catch {
                saveFailure = error as NSError
            }
            guard context.hasChanges,
                  try context.fetch(FetchDescriptor<Transcription>()).contains(where: { $0.id == pendingID }) else {
                throw FixtureFailure(description: "save failure did not leave the unsaved transcription pending")
            }

            let rejection: String?
            switch operation {
            case .historyDelete:
                let suiteName = "HaasSharedContextRegression.\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: suiteName) else {
                    throw FixtureFailure(description: "isolated defaults suite unavailable")
                }
                defer { defaults.removePersistentDomain(forName: suiteName) }
                let maintenance = HaasHistoryMaintenance(defaults: defaults,
                    recordingsDirectory: directory.appendingPathComponent("Recordings", isDirectory: true))
                do {
                    try maintenance.delete([history], context: context)
                    rejection = nil
                } catch { rejection = error.localizedDescription }
            case .replacementUpdate:
                rejection = HaasWordReplacementStore.updateWordReplacement(replacement,
                    original: "source-a", replacementText: "Changed Target", context: context)
            case .replacementRemove:
                rejection = HaasWordReplacementStore.removeWordReplacement(replacement, context: context)
            case .replacementMerge:
                rejection = HaasWordReplacementStore.addWordReplacement(original: "source-b", replacement: "Target",
                    existing: [replacement], context: context)
            }

            let histories = try context.fetch(FetchDescriptor<Transcription>())
            let rules = try context.fetch(FetchDescriptor<WordReplacement>())
            let remainingPending = histories.first { $0.id == pendingID }
            let remainingHistory = histories.first { $0.id == identifiers.0 }
            let remainingRule = rules.first { $0.id == identifiers.1 }
            return SharedContextObservation(
                operation: operation.rawValue,
                saveFailureDomain: saveFailure.domain, saveFailureCode: saveFailure.code,
                pendingPresent: remainingPending != nil, pendingText: remainingPending?.text,
                hasChanges: context.hasChanges,
                existingHistoryPresent: remainingHistory != nil, existingHistoryText: remainingHistory?.text,
                replacementCount: rules.count, originalText: remainingRule?.originalText,
                replacementText: remainingRule?.replacementText,
                rejected: rejection != nil, rejectionMessage: rejection
            )
        }
    }

    private static func makeContainer(directory: URL, allowsSave: Bool) throws -> ModelContainer {
        let schema = Schema([Transcription.self, WordReplacement.self])
        let history = ModelConfiguration("default", schema: Schema([Transcription.self]),
            url: directory.appendingPathComponent("default.store"), allowsSave: allowsSave, cloudKitDatabase: .none)
        let dictionary = ModelConfiguration("dictionary", schema: Schema([WordReplacement.self]),
            url: directory.appendingPathComponent("dictionary.store"), allowsSave: allowsSave, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: history, dictionary)
    }
}

@MainActor
final class HaasSharedContextMutationTests: XCTestCase {
    func testOtherMutationsPreserveHistoryWhoseSaveFailed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaasSharedContext-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for operation in SharedContextMutation.allCases {
            let result = try SharedContextRegressionCases.run(operation,
                directory: root.appendingPathComponent(operation.rawValue, isDirectory: true))
            XCTAssertTrue(result.violations.isEmpty,
                          "\(operation.rawValue): \(result.violations.joined(separator: "; "))")
        }
    }
}
