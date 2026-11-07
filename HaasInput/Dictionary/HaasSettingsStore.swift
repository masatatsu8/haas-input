import Combine
import Foundation

@MainActor
final class HaasSettingsStore: ObservableObject {
    static let shared = HaasSettingsStore()

    private enum Key {
        static let entries = "HaasVocabularyEntriesV1"
        static let executable = "HaasExecutablePath"
        static let model = "HaasModelPath"
        static let vadModel = "HaasVADModelPath"
    }

    @Published private(set) var entries: [HaasVocabularyEntry] = []
    @Published private(set) var loadError: String?
    @Published var executablePath: String {
        didSet { defaults.set(executablePath, forKey: Key.executable) }
    }
    @Published var modelPath: String {
        didSet { defaults.set(modelPath, forKey: Key.model) }
    }
    @Published var vadModelPath: String {
        didSet { defaults.set(vadModelPath, forKey: Key.vadModel) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        executablePath = defaults.string(forKey: Key.executable) ?? ""
        modelPath = defaults.string(forKey: Key.model) ?? ""
        vadModelPath = defaults.string(forKey: Key.vadModel) ?? ""
        if let storedValue = defaults.object(forKey: Key.entries) {
            guard let data = storedValue as? Data else {
                loadError = HaasVocabularyError.unreadableDictionary.localizedDescription
                return
            }
            do {
                let decoded = try JSONDecoder().decode([HaasVocabularyEntry].self, from: data)
                entries = try Self.validateEntries(decoded)
            } catch {
                loadError = HaasVocabularyError.unreadableDictionary.localizedDescription
            }
        }
    }

    func vocabularySnapshot() throws -> String {
        guard loadError == nil else { throw HaasVocabularyError.unreadableDictionary }
        return entries.map(\.wordsLine).joined(separator: "\n")
    }

    func vocabularyEntriesSnapshot() throws -> [HaasVocabularyEntry] {
        guard loadError == nil else { throw HaasVocabularyError.unreadableDictionary }
        return entries
    }

    func saveEntry(
        id: UUID? = nil,
        writtenForm: String,
        readings: [String],
        category: HaasVocabularyCategory
    ) throws {
        guard loadError == nil else { throw HaasVocabularyError.unreadableDictionary }
        let entry = try HaasVocabularyEntry(
            id: id ?? UUID(), writtenForm: writtenForm, readings: readings, category: category
        ).validated()
        var updated = entries
        if let id {
            guard let index = updated.firstIndex(where: { $0.id == id }) else {
                throw HaasVocabularyError.missingEntry
            }
            updated[index] = entry
        } else {
            updated.append(entry)
        }
        try persist(Self.validateEntries(updated))
    }

    func removeEntry(id: UUID) throws {
        guard loadError == nil else { throw HaasVocabularyError.unreadableDictionary }
        try persist(entries.filter { $0.id != id })
    }

    func exportVocabulary() throws -> Data {
        guard loadError == nil else { throw HaasVocabularyError.unreadableDictionary }
        return try HaasVocabularyArchive.encode(entries)
    }

    func previewImport(_ data: Data) throws -> HaasVocabularyImportPreview {
        guard loadError == nil else { throw HaasVocabularyError.unreadableDictionary }
        let archive = try HaasVocabularyArchive.decode(data)
        let currentByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.comparisonKey, $0) })
        let items = try archive.entries.map { shared in
            let incoming = try shared.localEntry()
            return HaasVocabularyImportPreview.Item(incoming: incoming, existing: currentByName[incoming.comparisonKey])
        }
        return HaasVocabularyImportPreview(baseEntries: entries, items: items)
    }

    func applyImport(
        _ preview: HaasVocabularyImportPreview,
        replacing selectedNames: Set<String> = []
    ) throws -> HaasVocabularyImportResult {
        guard loadError == nil else { throw HaasVocabularyError.unreadableDictionary }
        guard entries == preview.baseEntries else { throw HaasVocabularyArchiveError.dictionaryChanged }
        let conflicts = Set(preview.items.filter { $0.status == .conflict }.map(\.id))
        guard selectedNames.isSubset(of: conflicts) else { throw HaasVocabularyArchiveError.invalidSelection }

        var updated = entries
        for item in preview.items {
            if let existing = item.existing {
                if selectedNames.contains(item.id), let index = updated.firstIndex(where: { $0.id == existing.id }) {
                    updated[index] = try HaasSharedVocabularyEntry(item.incoming).localEntry(id: existing.id)
                }
            } else {
                updated.append(item.incoming)
            }
        }
        try persist(Self.validateEntries(updated))
        return HaasVocabularyImportResult(
            added: preview.addedCount,
            updated: selectedNames.count,
            kept: preview.unchangedCount + preview.conflictCount - selectedNames.count
        )
    }

    private func persist(_ updated: [HaasVocabularyEntry]) throws {
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: Key.entries)
        entries = updated
    }

    private static func validateEntries(_ entries: [HaasVocabularyEntry]) throws -> [HaasVocabularyEntry] {
        var names = Set<String>()
        var ids = Set<UUID>()
        return try entries.map { entry in
            let validated = try entry.validated()
            guard names.insert(validated.comparisonKey).inserted, ids.insert(validated.id).inserted else {
                throw HaasVocabularyError.duplicateName
            }
            return validated
        }
    }
}
