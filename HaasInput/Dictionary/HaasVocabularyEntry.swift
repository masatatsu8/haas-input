import Foundation

enum HaasVocabularyCategory: String, Codable, CaseIterable, Identifiable {
    case company
    case product
    case person
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "service" {
            self = .product
        } else if let category = Self(rawValue: value) {
            self = category
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown Haas dictionary category")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .company: return "組織"
        case .product: return "製品"
        case .person: return "人名"
        case .other: return "その他"
        }
    }
}

struct HaasVocabularyEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var writtenForm: String
    var readings: [String]
    var category: HaasVocabularyCategory

    var wordsLine: String {
        readings.isEmpty ? writtenForm : writtenForm + "=" + readings.joined(separator: ",")
    }

    func validated() throws -> HaasVocabularyEntry {
        let name = writtenForm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HaasVocabularyError.emptyName }
        guard !Self.containsControlCharacter(writtenForm), !name.contains("=") else {
            throw HaasVocabularyError.invalidName
        }

        var cleanedReadings: [String] = []
        for reading in readings {
            let cleaned = reading.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Self.containsControlCharacter(reading), !cleaned.contains("="), !cleaned.contains(",") else {
                throw HaasVocabularyError.invalidReading
            }
            guard !cleaned.isEmpty else { continue }
            if !cleanedReadings.contains(cleaned) { cleanedReadings.append(cleaned) }
        }
        return HaasVocabularyEntry(id: id, writtenForm: name, readings: cleanedReadings, category: category)
    }

    var comparisonKey: String {
        writtenForm.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private static func containsControlCharacter(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .controlCharacters.union(.newlines)) != nil
    }
}

enum HaasVocabularyError: LocalizedError {
    case emptyName
    case invalidName
    case invalidReading
    case duplicateName
    case missingEntry
    case unreadableDictionary

    var errorDescription: String? {
        switch self {
        case .emptyName: return "正式表記を入力してください。"
        case .invalidName: return "正式表記には改行、制御文字、= を使えません。"
        case .invalidReading: return "読みには改行、制御文字、= を使えません。複数の読みはカンマで区切ってください。"
        case .duplicateName: return "同じ名前が既に登録されています。既存の項目を編集してください。大文字小文字・全角半角・空白だけの違いも同じ名前として扱います。"
        case .missingEntry: return "この項目は削除されています。辞書を開き直してください。"
        case .unreadableDictionary: return "保存したHaas辞書を読み込めません。辞書データは変更していません。"
        }
    }
}
