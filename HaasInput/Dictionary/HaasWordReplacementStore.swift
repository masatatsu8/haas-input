import Foundation
import SwiftData
import os

@MainActor
enum HaasWordReplacementStore {
    private static let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "WordReplacementStore")
    private static let unsavedChangesMessage = "保存できていない変更があります。ホームで履歴の保存を再試行してから置換ルールを編集してください。"

    /// Adds a word replacement entry (original may be comma-separated).
    /// Returns an error message string if something went wrong, nil on success.
    @discardableResult
    static func addWordReplacement(
        original: String,
        replacement: String,
        existing: [WordReplacement],
        context: ModelContext
    ) -> String? {
        guard !context.hasChanges else { return unsavedChangesMessage }
        let tokens = WordReplacementVariants.parse(original)

        let destination = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !tokens.isEmpty, !destination.isEmpty else { return "元の語と置換先を入力してください。" }

        let destinationKey = WordReplacementVariants.destinationKey(for: destination)

        for existingEntry in existing {
            let existingTokens = WordReplacementVariants.parse(existingEntry.originalText)

            for token in tokens {
                if WordReplacementVariants.contains(token, in: existingTokens),
                    WordReplacementVariants.destinationKey(for: existingEntry.replacementText)
                        != destinationKey
                {
                    return "「\(token)」は別の置換先で登録されています。"
                }
            }
        }

        let destinationMatches = existing
            .filter {
                WordReplacementVariants.destinationKey(for: $0.replacementText) == destinationKey
            }
            .sorted {
                if $0.dateAdded != $1.dateAdded { return $0.dateAdded < $1.dateAdded }
                return $0.id.uuidString < $1.id.uuidString
            }

        // Checked for every result, not only when an existing rule is reused:
        // creating a brand new rule can loop just as easily as merging into one.
        if WordReplacementVariants.wouldCreateCycle(
            newSources: tokens.map { (source: $0, destination: destination) },
            in: existing.map {
                (originalText: $0.originalText, replacementText: $0.replacementText)
            }
        ) {
            return "置換が循環するため保存できません。元の語と置換先を確認してください。"
        }

        if let canonical = destinationMatches.first {
            let mergedTokens = destinationMatches.flatMap {
                WordReplacementVariants.parse($0.originalText)
            } + tokens

            canonical.originalText = WordReplacementVariants.serialize(mergedTokens)
            canonical.replacementText = destination
            for duplicate in destinationMatches.dropFirst() {
                context.delete(duplicate)
            }
        } else {
            let entry = WordReplacement(
                originalText: WordReplacementVariants.serialize(tokens),
                replacementText: destination
            )
            context.insert(entry)
        }
        do {
            try context.save()
            return nil
        } catch {
            context.rollback()
            logger.error("Replacement save failed: \(String(describing: error), privacy: .private)")
            return "置換ルールを保存できませんでした。変更は反映していません。"
        }
    }

    /// Updates an existing replacement and consolidates rows with the same
    /// case-sensitive, normalized destination.
    @discardableResult
    static func updateWordReplacement(
        _ replacement: WordReplacement,
        original: String,
        replacementText: String,
        context: ModelContext
    ) -> String? {
        guard !context.hasChanges else { return unsavedChangesMessage }
        let tokens = WordReplacementVariants.parse(original)
        let destination = replacementText.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !tokens.isEmpty, !destination.isEmpty else { return "元の語と置換先を入力してください。" }

        let existing: [WordReplacement]
        do {
            existing = try context.fetch(FetchDescriptor<WordReplacement>())
        } catch {
            return "置換ルールを読み込めませんでした。"
        }

        let destinationKey = WordReplacementVariants.destinationKey(for: destination)
        let otherReplacements = existing.filter {
            $0.persistentModelID != replacement.persistentModelID
        }

        for existingEntry in otherReplacements {
            let existingTokens = WordReplacementVariants.parse(existingEntry.originalText)
            for token in tokens {
                if WordReplacementVariants.contains(token, in: existingTokens),
                    WordReplacementVariants.destinationKey(for: existingEntry.replacementText)
                        != destinationKey
                {
                    return "「\(token)」は別の置換先で登録されています。"
                }
            }
        }

        let destinationMatches = otherReplacements
            .filter {
                WordReplacementVariants.destinationKey(for: $0.replacementText) == destinationKey
            }
            .sorted(by: replacementOrder)

        // The edited rule is excluded from the graph, so pointing it at a new
        // destination is validated the same way whether or not it merges.
        if WordReplacementVariants.wouldCreateCycle(
            newSources: tokens.map { (source: $0, destination: destination) },
            in: otherReplacements.map {
                (originalText: $0.originalText, replacementText: $0.replacementText)
            }
        ) {
            return "置換が循環するため保存できません。元の語と置換先を確認してください。"
        }

        if let canonical = destinationMatches.first {
            let mergedTokens = destinationMatches.flatMap {
                WordReplacementVariants.parse($0.originalText)
            } + tokens

            canonical.originalText = WordReplacementVariants.serialize(mergedTokens)
            canonical.replacementText = destination
            context.delete(replacement)
            for duplicate in destinationMatches.dropFirst() {
                context.delete(duplicate)
            }
        } else {
            replacement.originalText = WordReplacementVariants.serialize(tokens)
            replacement.replacementText = destination
        }

        do {
            try context.save()
            return nil
        } catch {
            context.rollback()
            logger.error("Replacement update failed: \(String(describing: error), privacy: .private)")
            return "置換ルールの変更を保存できませんでした。"
        }
    }

    @discardableResult
    static func removeWordReplacement(_ replacement: WordReplacement, context: ModelContext) -> String? {
        guard !context.hasChanges else { return unsavedChangesMessage }
        context.delete(replacement)
        do {
            try context.save()
            return nil
        } catch {
            context.rollback()
            logger.error("Replacement update failed: \(String(describing: error), privacy: .private)")
            return "置換ルールを削除できませんでした。"
        }
    }

    private static func replacementOrder(_ lhs: WordReplacement, _ rhs: WordReplacement) -> Bool {
        if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded < rhs.dateAdded }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
