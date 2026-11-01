import Foundation

struct HaasSessionTranscript {
    private let replacements: WordReplacementPlan
    private var ledger = HaasSegmentLedger()
    private var committedIDs = Set<String>()
    private var finalizedIDs = Set<String>()
    private var rawCommittedText = ""

    init(replacements: WordReplacementPlan) {
        self.replacements = replacements
    }

    var text: String { ledger.fullText }

    mutating func commit(id: String, rawText: String) -> String? {
        guard committedIDs.insert(id).inserted else { return nil }
        let formatted = replacements.apply(to: rawText)
        rawCommittedText += rawText
        ledger.append(id: id, text: formatted)
        return formatted
    }

    @discardableResult
    mutating func finalize(id: String, text: String) -> Bool {
        guard !finalizedIDs.contains(id), ledger.replacePendingText(text, for: id) else { return false }
        finalizedIDs.insert(id)
        return true
    }

    func preview(rawText: String) -> String {
        guard rawText.hasPrefix(rawCommittedText) else { return text }
        return text + rawText.dropFirst(rawCommittedText.count)
    }
}
