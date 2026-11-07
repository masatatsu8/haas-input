import Foundation

struct HaasSessionTranscript {
    private let replacements: WordReplacementPlan
    private let vocabulary: HaasVocabularyMatcher
    private var ledger = HaasSegmentLedger()
    private var committedIDs = Set<String>()
    private var finalizedIDs = Set<String>()
    private var rawCommittedText = ""

    init(replacements: WordReplacementPlan, vocabulary: HaasVocabularyMatcher = .empty) {
        self.replacements = replacements
        self.vocabulary = vocabulary
    }

    var text: String { ledger.fullText }

    mutating func commit(id: String, rawText: String) -> String? {
        guard committedIDs.insert(id).inserted else { return nil }
        let formatted = vocabulary.apply(
            to: replacements.apply(to: rawText),
            protecting: replacements.replacementTexts
        )
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

    /// 保留した末尾の「。」を、録音の終わりに区切りとして足す。原文は変えないので、プレビューの照合は崩れない
    @discardableResult
    mutating func appendHeldPeriod(id: String) -> Bool {
        guard !committedIDs.contains(id), ledger.append(id: id, text: "。") else { return false }
        committedIDs.insert(id)
        finalizedIDs.insert(id)
        return true
    }

    func preview(rawText: String) -> String {
        guard rawText.hasPrefix(rawCommittedText) else { return text }
        return text + rawText.dropFirst(rawCommittedText.count)
    }
}
