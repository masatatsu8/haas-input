import Foundation

struct HaasSharedVocabularyEntry: Codable, Equatable {
    let writtenForm: String
    let readings: [String]
    let category: HaasVocabularyCategory

    init(_ entry: HaasVocabularyEntry) {
        writtenForm = entry.writtenForm
        readings = entry.readings
        category = entry.category
    }

    init(writtenForm: String, readings: [String], category: HaasVocabularyCategory) {
        self.writtenForm = writtenForm
        self.readings = readings
        self.category = category
    }

    func localEntry(id: UUID = UUID()) throws -> HaasVocabularyEntry {
        try HaasVocabularyEntry(id: id, writtenForm: writtenForm, readings: readings, category: category).validated()
    }
}

struct HaasVocabularyArchive: Codable {
    static let formatIdentifier = "voiceink.haas-vocabulary"
    static let currentSchemaVersion = 2
    static let maximumFileBytes = 1_048_576
    static let maximumEntries = 1_000

    let format: String
    let schemaVersion: Int
    let entries: [HaasSharedVocabularyEntry]

    private struct Header: Decodable {
        let format: String
        let schemaVersion: Int
    }

    private struct Payload: Decodable {
        struct Entry: Decodable {
            let writtenForm: String
            let readings: [String]
            let category: String
        }
        let entries: [Entry]
    }

    private init(entries: [HaasSharedVocabularyEntry]) {
        format = Self.formatIdentifier
        schemaVersion = Self.currentSchemaVersion
        self.entries = entries
    }

    static func encode(_ entries: [HaasVocabularyEntry]) throws -> Data {
        let archive = HaasVocabularyArchive(entries: try validated(entries.map(HaasSharedVocabularyEntry.init)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(archive)
        guard data.count <= maximumFileBytes else { throw HaasVocabularyArchiveError.fileTooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> HaasVocabularyArchive {
        guard data.count <= maximumFileBytes else { throw HaasVocabularyArchiveError.fileTooLarge }
        let decoder = JSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw HaasVocabularyArchiveError.invalidFile
        }
        guard header.format == formatIdentifier else { throw HaasVocabularyArchiveError.unsupportedFormat }
        guard header.schemaVersion == 1 || header.schemaVersion == 2 else {
            throw HaasVocabularyArchiveError.unsupportedVersion(header.schemaVersion)
        }
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            throw HaasVocabularyArchiveError.invalidFile
        }
        let entries = try payload.entries.map { entry in
            let category: HaasVocabularyCategory
            switch (header.schemaVersion, entry.category) {
            case (_, "company"): category = .company
            case (_, "product"), (1, "service"): category = .product
            case (2, "person"): category = .person
            case (2, "other"): category = .other
            default: throw HaasVocabularyArchiveError.invalidFile
            }
            return HaasSharedVocabularyEntry(writtenForm: entry.writtenForm, readings: entry.readings, category: category)
        }
        return HaasVocabularyArchive(entries: try validated(entries))
    }

    private static func validated(_ entries: [HaasSharedVocabularyEntry]) throws -> [HaasSharedVocabularyEntry] {
        guard entries.count <= maximumEntries else { throw HaasVocabularyArchiveError.tooManyEntries }
        var names = Set<String>()
        return try entries.map { shared in
            let entry = try shared.localEntry()
            guard names.insert(entry.comparisonKey).inserted else {
                throw HaasVocabularyArchiveError.duplicateName(entry.writtenForm)
            }
            return HaasSharedVocabularyEntry(entry)
        }
    }
}

struct HaasVocabularyImportPreview: Identifiable {
    struct Item: Identifiable {
        enum Status {
            case added
            case unchanged
            case conflict
        }

        let incoming: HaasVocabularyEntry
        let existing: HaasVocabularyEntry?

        var id: String { incoming.comparisonKey }
        var status: Status {
            guard let existing else { return .added }
            return HaasSharedVocabularyEntry(existing) == HaasSharedVocabularyEntry(incoming) ? .unchanged : .conflict
        }
    }

    let id = UUID()
    let baseEntries: [HaasVocabularyEntry]
    let items: [Item]

    var addedCount: Int { items.filter { $0.status == .added }.count }
    var unchangedCount: Int { items.filter { $0.status == .unchanged }.count }
    var conflictCount: Int { items.filter { $0.status == .conflict }.count }
}

struct HaasVocabularyImportResult {
    let added: Int
    let updated: Int
    let kept: Int

    var message: String {
        "\(added) 件を追加し、\(updated) 件を更新しました。\(kept) 件は現在の登録を保持しました。"
    }
}

enum HaasVocabularyArchiveError: LocalizedError {
    case invalidFile
    case unsupportedFormat
    case unsupportedVersion(Int)
    case fileTooLarge
    case tooManyEntries
    case duplicateName(String)
    case dictionaryChanged
    case invalidSelection

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "Haas辞書のJSONファイルを読み込めません。"
        case .unsupportedFormat: return "このファイルはHaas辞書の共有形式ではありません。"
        case .unsupportedVersion(let version): return "この辞書形式のバージョン (\(version)) には対応していません。"
        case .fileTooLarge: return "辞書ファイルは 1 MiB 以下にしてください。"
        case .tooManyEntries: return "一度に共有できる用語は 1,000 件までです。"
        case .duplicateName(let name): return "共有ファイル内で名前が重複しています: \(name)"
        case .dictionaryChanged: return "確認中に辞書が変更されました。ファイルを選び直して内容を確認してください。"
        case .invalidSelection: return "更新する項目が一致しません。ファイルを選び直してください。"
        }
    }
}
