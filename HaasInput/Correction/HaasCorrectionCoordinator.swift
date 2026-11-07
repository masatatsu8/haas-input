import AppKit
import Foundation
import SwiftData
import os

/// ポップアップに出す、訂正の始まりの状態
struct HaasCorrectionDraft: Equatable {
    let originalText: String
    let transcriptionID: UUID?
    let decision: HaasReplacementDecision
}

/// 確定の結果。copied と failed の文は利用者に見せる
enum HaasCorrectionResult: Equatable {
    case unchanged, replaced, copied(String), failed(String)
}

struct HaasCorrectionOutcome: Equatable {
    let result: HaasCorrectionResult
    let dictionaryErrors: [String]
    let historyError: String?
}

/// 直前の入力の訂正 (置き換え・コピー・辞書の登録・履歴の書き戻し) をまとめる。画面は持たない
@MainActor
final class HaasCorrectionCoordinator: ObservableObject {
    static let copiedMessage = "直した文をコピーしました。⌘V で貼れます"
    static let interruptedMessage = "入れ直しを途中で止めました。⌘V で直した文を貼れます"
    static let copyFailedMessage = "直した文をコピーできませんでした。もう一度開くと、直した文から始められます"
    static let emptyMessage = "直した文が空なので、何もしませんでした"
    static let unsavedHistoryMessage = "履歴を書き換えられませんでした。保存されていない履歴があります"
    static let historyFailedMessage = "履歴を書き換えられませんでした"

    /// 判定に使う直前の入力。配信の記録か、訂正の後にメモリで持つもの
    private struct LastInput {
        let sessionID: UUID?
        let transcriptionID: UUID?
        let text: String
        let allSegmentsPosted: Bool
        let target: (any HaasInputTargetChecking)?
        let watchToken: UUID?
        /// 入れる前の欄の記録。読める欄では、これに入れた文を足したものとちょうど一致するときだけ消す
        let insertionBaseline: HaasInsertionBaseline?
        /// 値があれば、入力先の状態にかかわらずコピーだけにする
        let forcedCopyReason: HaasCopyReason?
        /// 直した文をまだクリップボードに入れられていない。同じ文で確定しても、コピーだけやり直す
        var copyPending = false
    }

    /// begin から confirm / cancel までに保つ状態
    private struct Session {
        let draft: HaasCorrectionDraft
        let input: LastInput
        /// 読める欄で自動で置き換えるときの、消している途中の欄のあるべき姿
        let expectation: HaasFieldExpectation?
        /// 閉じた後に前面へ戻す先 (置き換えの入力先とは別に持つ)
        let returnTarget: (any HaasInputTargetChecking)?
    }

    private let delivery: any HaasDeliveredInputProviding
    private let monitor: any HaasInputWatching
    private let replacer: any HaasCorrectionReplacing
    private let settings: HaasSettingsStore
    private let modelContext: ModelContext
    private let isIdle: () -> Bool
    private let captureReturnTarget: @MainActor () -> (any HaasInputTargetChecking)?
    private let waitForFocus: @MainActor (any HaasInputTargetChecking) async -> Void
    private let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "HaasCorrection")

    /// 訂正の後にメモリで持つ「直前の入力」。同じ録音の記録が続く間だけ使う
    private var carried: LastInput?
    private var session: Session?

    init(
        delivery: any HaasDeliveredInputProviding,
        monitor: any HaasInputWatching,
        replacer: any HaasCorrectionReplacing,
        settings: HaasSettingsStore,
        modelContext: ModelContext,
        isIdle: @escaping () -> Bool,
        captureReturnTarget: @escaping @MainActor () -> (any HaasInputTargetChecking)? =
            HaasCorrectionCoordinator.captureFrontmostTarget,
        waitForFocus: @escaping @MainActor (any HaasInputTargetChecking) async -> Void =
            HaasCorrectionCoordinator.waitUntilFocused
    ) {
        self.delivery = delivery
        self.monitor = monitor
        self.replacer = replacer
        self.settings = settings
        self.modelContext = modelContext
        self.isIdle = isIdle
        self.captureReturnTarget = captureReturnTarget
        self.waitForFocus = waitForFocus
    }

    /// 本番の戻り先。入力欄を取れなければ前面のアプリを包む
    static func captureFrontmostTarget() -> (any HaasInputTargetChecking)? {
        if let target = HaasPasteTarget.capture() { return target }
        return NSWorkspace.shared.frontmostApplication.map { HaasFrontmostApplicationTarget(application: $0) }
    }

    /// 本番の待ち。入力先が前面に戻るまで最大0.5秒待つ
    static func waitUntilFocused(_ target: any HaasInputTargetChecking) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while target.rejectionReason() != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 録音中・認識中。このときはホットキーで何もしない
    var isBusy: Bool { !isIdle() }

    /// ポップアップを出す前 (自分の窓が key になる前) に呼ぶ。録音中・認識中や、直す文がなければ nil
    func begin() -> HaasCorrectionDraft? {
        // 開けなかったときに、前の状態を確定できないようにする
        session = nil
        guard isIdle() else { return nil }
        let returnTarget = captureReturnTarget()
        guard let input = currentInput() else { return nil }
        let (decision, field) = evaluate(input)
        var expectation: HaasFieldExpectation?
        if case .replaceAutomatically = decision, case let .readable(_, textAfterCaret, _) = field,
            case let .readable(textBeforeInsertion)? = input.insertionBaseline
        {
            // カーソルの後ろは開いたときの中身で固定し、消している間に変われば止める
            expectation = HaasFieldExpectation(
                textBeforeInsertion: textBeforeInsertion, insertedText: input.text, textAfterCaret: textAfterCaret)
        }
        let draft = HaasCorrectionDraft(
            originalText: input.text, transcriptionID: input.transcriptionID, decision: decision)
        session = Session(draft: draft, input: input, expectation: expectation, returnTarget: returnTarget)
        return draft
    }

    /// 何もせずに閉じたとき。戻り先を前面に戻す
    func cancel() {
        let returnTarget = session?.returnTarget
        session = nil
        _ = returnTarget?.activate()
    }

    func suggestions(for corrected: String) -> HaasSuggestionResult {
        guard let draft = session?.draft, let entries = try? settings.vocabularyEntriesSnapshot() else {
            return HaasSuggestionResult(suggestions: [], usedDictionaryForms: [])
        }
        return HaasCorrectionSuggester.suggestions(original: draft.originalText, corrected: corrected, entries: entries)
    }

    func confirm(
        _ draft: HaasCorrectionDraft, corrected: String, register: [HaasDictionarySuggestion]
    ) async -> HaasCorrectionOutcome {
        let closing = session
        session = nil
        // 閉じたら、置き換えない経路や draft が合わないときも含めて、必ず戻り先へ戻す
        _ = closing?.returnTarget?.activate()
        let current = closing?.draft == draft ? closing : nil

        guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return HaasCorrectionOutcome(result: .failed(Self.emptyMessage), dictionaryErrors: [], historyError: nil)
        }
        if let current, current.input.copyPending, corrected == draft.originalText {
            // 前回コピーできなかった直した文。辞書と履歴は済んでいるので、コピーだけやり直す
            let result = copy(corrected, session: current, message: Self.copiedMessage)
            return HaasCorrectionOutcome(result: result, dictionaryErrors: [], historyError: nil)
        }
        guard corrected != draft.originalText else {
            return HaasCorrectionOutcome(result: .unchanged, dictionaryErrors: [], historyError: nil)
        }
        let result = await deliver(corrected, session: current)
        let dictionaryErrors = register.compactMap(registerSuggestion)
        let historyError = writeHistory(transcriptionID: draft.transcriptionID, text: corrected)
        return HaasCorrectionOutcome(result: result, dictionaryErrors: dictionaryErrors, historyError: historyError)
    }

    // MARK: - 直前の入力と判定

    private func currentInput() -> LastInput? {
        let delivered = delivery.lastDeliveredInput
        if let carried, carried.sessionID == delivered?.sessionID {
            return LastInput(
                sessionID: carried.sessionID,
                transcriptionID: delivered?.transcriptionID ?? carried.transcriptionID,
                text: carried.text, allSegmentsPosted: carried.allSegmentsPosted, target: carried.target,
                watchToken: carried.watchToken, insertionBaseline: carried.insertionBaseline,
                forcedCopyReason: carried.forcedCopyReason,
                copyPending: carried.copyPending)
        }
        if let delivered {
            // 新しい録音の記録が来たら、前の訂正で持っていた入力は使わない
            carried = nil
            return LastInput(
                sessionID: delivered.sessionID, transcriptionID: delivered.transcriptionID, text: delivered.text,
                allSegmentsPosted: delivered.allSegmentsPosted, target: delivered.target,
                watchToken: delivered.watchToken, insertionBaseline: delivered.insertionBaseline,
                forcedCopyReason: nil)
        }
        return latestHistoryInput()
    }

    /// 配信の記録がないとき (起動し直した後など) は、最新の履歴の文を出す。置き換えはしない
    private func latestHistoryInput() -> LastInput? {
        var request = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\Transcription.timestamp, order: .reverse)])
        request.fetchLimit = 20
        let skipped = [TranscriptionStatus.canceled.rawValue, TranscriptionStatus.failed.rawValue]
        guard let rows = try? modelContext.fetch(request),
            let row = rows.first(where: { row in
                !skipped.contains(row.transcriptionStatus ?? "")
                    && !row.preferredHistoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else { return nil }
        return LastInput(
            sessionID: nil, transcriptionID: row.id, text: row.preferredHistoryText, allSegmentsPosted: false,
            target: nil, watchToken: nil, insertionBaseline: nil, forcedCopyReason: .noRecord)
    }

    /// 入力先と見張りの今の状態から判定する
    private func evaluate(_ input: LastInput) -> (HaasReplacementDecision, HaasFieldState) {
        if let reason = input.forcedCopyReason { return (.copyOnly(reason), .unreadable) }
        let targetUnchanged = input.target.map { $0.rejectionReason() == nil } ?? false
        let field = targetUnchanged ? (input.target?.fieldState() ?? .unreadable) : .unreadable
        let watchedClean = input.watchToken.map { monitor.isClean(for: $0) } ?? false
        let decision = HaasReplacementDecision.decide(HaasReplacementContext(
            insertedText: input.text, allSegmentsPosted: input.allSegmentsPosted,
            watchedWithoutUserInput: watchedClean, targetUnchanged: targetUnchanged, field: field,
            insertionBaseline: input.insertionBaseline))
        return (decision, field)
    }

    // MARK: - 置き換えとコピー

    private func deliver(_ corrected: String, session: Session?) async -> HaasCorrectionResult {
        guard let session, let target = session.input.target, let token = session.input.watchToken else {
            return copy(corrected, session: session, message: Self.copiedMessage)
        }
        if case .copyOnly = session.draft.decision {
            return copy(corrected, session: session, message: Self.copiedMessage)
        }
        // 前面が入力先に戻るのを待ってから、開いたときと同じ判定かを確かめ直す
        await waitForFocus(target)
        let decision = HaasReplacementDecision.confirmed(shown: session.draft.decision, now: evaluate(session.input).0)
        let deleteCount: Int
        let expectation: HaasFieldExpectation?
        switch decision {
        case let .replaceAutomatically(count):
            guard let shownExpectation = session.expectation else {
                return copy(corrected, session: session, message: Self.copiedMessage)
            }
            deleteCount = count
            expectation = shownExpectation
        case let .replaceAfterConfirmation(count):
            // 読めない入力先は、利用者が消す文字数を確かめて押したので、欄の中身は確かめない
            deleteCount = count
            expectation = nil
        case let .copyOnly(reason):
            logger.notice("correction phase=confirm result=copy reason=\(String(describing: reason), privacy: .public)")
            return copy(corrected, session: session, message: Self.copiedMessage)
        }

        let monitor = self.monitor
        let isSafe = { target.rejectionReason() == nil && monitor.isClean(for: token) }
        let outcome = await replacer.replace(
            corrected, deleteCount: deleteCount,
            awaitField: { deleted in
                guard isSafe() else { return false }
                guard let expectation else { return true }
                return await Self.awaitFieldProgress(
                    expectation: expectation, deleted: deleted, readField: { target.fieldState() })
            },
            // Backspace の keyDown の直前に同期で呼ばれる。待った間の操作も見逃さないよう、ここで改めて全部確かめる
            shouldContinue: { deleted in
                guard isSafe() else { return false }
                guard let expectation else { return true }
                let field = target.fieldState()
                guard HaasReplacementDecision.fieldMatchesProgress(field, expectation: expectation, deleted: deleted)
                else { return false }
                // まだ消す文字があるなら、次の Backspace がカーソルの後ろの文字まで消さないことを確かめる
                return deleted >= deleteCount || !HaasReplacementDecision.backspaceMayDeleteBeyondCaret(field)
            },
            pasteGuard: { phase in
                guard isSafe() else { return false }
                switch phase {
                case .beforeCommand, .beforeV:
                    // ⌘ を押した後に選択範囲が変わると、貼り付けで既存の文を消すので、V の前にも確かめる
                    guard let expectation else { return true }
                    return HaasReplacementDecision.fieldMatchesProgress(
                        target.fieldState(), expectation: expectation, deleted: deleteCount)
                case .afterCommand:
                    // 貼った分だけ中身が変わるので、入力先と見張りだけを確かめる
                    return true
                }
            })
        logger.notice("correction phase=replace outcome=\(String(describing: outcome), privacy: .public) app=\(target.diagnosticAppIdentifier, privacy: .public)")

        guard outcome == .completed else {
            // 完了以外は、この入力で二度と置き換えない。後から始まった別の見張りは止めない
            if monitor.isClean(for: token) { monitor.invalidate() }
            // 置き換えの手順は元のクリップボードを戻すので、直した文を改めてコピーする
            return copy(corrected, session: session, message: Self.interruptedMessage)
        }
        // 直した文と同じ入力先を、新しい「直前の入力」として持つ。貼った後に操作があれば見張りを始め直さない
        let newToken = monitor.isClean(for: token) ? monitor.startWatching() : nil
        carried = LastInput(
            sessionID: session.input.sessionID, transcriptionID: session.input.transcriptionID, text: corrected,
            allSegmentsPosted: true, target: target, watchToken: newToken,
            insertionBaseline: session.input.insertionBaseline, forcedCopyReason: nil)
        return .replaced
    }

    /// 消している途中の欄を、更新が追いつくまで少しの間だけ読み直して確かめる。
    /// ブラウザなどでは Backspace の後しばらく前の中身を返すことがあるため、
    /// 1つ前の段階 (deleted - 1) とちょうど一致する間だけ待つ。それ以外の中身はすぐに止める。
    /// 期待どおりの中身とちょうど一致したときだけ true。待つのも読み直すのも MainActor の上で行う
    static func awaitFieldProgress(
        expectation: HaasFieldExpectation, deleted: Int,
        readField: () -> HaasFieldState,
        window: Duration = .milliseconds(150),
        pollInterval: Duration = .milliseconds(10)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: window)
        while true {
            let field = readField()
            if HaasReplacementDecision.fieldMatchesProgress(field, expectation: expectation, deleted: deleted) {
                return true
            }
            // deleted == 0 に前の段階はない。前の段階のまま以外は待たない
            guard deleted > 0,
                HaasReplacementDecision.fieldMatchesProgress(field, expectation: expectation, deleted: deleted - 1),
                ContinuousClock.now < deadline, !Task.isCancelled
            else { return false }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// 置き換えを完了しなかった経路の終わり。直した文をコピーし、次に開いたときは直した文から始める。
    /// 入力先の中身は直した文と確かめられない (元のまま、または途中まで消えている) ので、置き換えはしない
    private func copy(_ corrected: String, session: Session?, message: String) -> HaasCorrectionResult {
        let copied = replacer.copy(corrected)
        if let input = session?.input {
            carried = LastInput(
                sessionID: input.sessionID, transcriptionID: input.transcriptionID, text: corrected,
                allSegmentsPosted: false, target: nil, watchToken: nil, insertionBaseline: nil,
                forcedCopyReason: .alreadyCorrected,
                copyPending: !copied)
        }
        return copied ? .copied(message) : .failed(Self.copyFailedMessage)
    }

    // MARK: - 辞書

    /// 選ばれた候補を1件登録する。失敗したら理由を返す
    private func registerSuggestion(_ suggestion: HaasDictionarySuggestion) -> String? {
        let form = suggestion.writtenForm
        switch suggestion.kind {
        case .replacement:
            let label = "『\(suggestion.before)』→『\(form)』"
            guard let existing = try? modelContext.fetch(FetchDescriptor<WordReplacement>()) else {
                return "\(label): 置換ルールを読み込めませんでした。"
            }
            return HaasWordReplacementStore.addWordReplacement(
                original: suggestion.before, replacement: form, existing: existing, context: modelContext
            ).map { "\(label): \($0)" }
        case .newWord:
            do {
                let entries = try settings.vocabularyEntriesSnapshot()
                if let problem = readingProblem(suggestion, addingTo: nil, entries: entries) { return problem }
                try settings.saveEntry(writtenForm: form, readings: [reading(of: suggestion)], category: .other)
                return nil
            } catch {
                return "『\(form)』: \(error.localizedDescription)"
            }
        case let .addReading(entryID):
            do {
                let entries = try settings.vocabularyEntriesSnapshot()
                guard let entry = entries.first(where: { $0.id == entryID }) else {
                    throw HaasVocabularyError.missingEntry
                }
                // ポップアップを開いている間に辞書の画面で改名されていれば、選ばれた語とは別の語になっている
                guard entry.writtenForm == form else { return "『\(form)』は辞書で変更されたため、読みを追加しませんでした" }
                if let problem = readingProblem(suggestion, addingTo: entry, entries: entries) { return problem }
                try settings.saveEntry(
                    id: entryID, writtenForm: entry.writtenForm, readings: entry.readings + [reading(of: suggestion)],
                    category: entry.category)
                return nil
            } catch {
                return "『\(form)』: \(error.localizedDescription)"
            }
        }
    }

    private func reading(of suggestion: HaasDictionarySuggestion) -> String {
        suggestion.reading.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 登録した後の語が照合で効かないなら理由を返す。短すぎる読みや、別の語と同じキーを持つ語は、
    /// 照合で両方が効かなくなる。キーは照合と同じ方法で作り、読みのほかにカナだけの正式表記も含める
    /// - existing: 読みを足す先の語。新しい語なら nil
    private func readingProblem(
        _ suggestion: HaasDictionarySuggestion, addingTo existing: HaasVocabularyEntry?,
        entries: [HaasVocabularyEntry]
    ) -> String? {
        let form = suggestion.writtenForm
        let reading = reading(of: suggestion)
        guard !reading.isEmpty else { return "『\(form)』の読みが空なので登録しませんでした" }
        guard let key = HaasVocabularyMatcher.key(forReading: reading) else {
            return "『\(form)』の読み『\(reading)』は照合に使えないので登録しませんでした"
        }
        guard key.count >= HaasVocabularyMatcher.minimumKeyLength else {
            return "『\(form)』の読み『\(reading)』は短すぎるので登録しませんでした"
        }
        // 登録で増えるキー。新しい語なら、カナだけの正式表記のキーも増える
        let current = Set(existing.map(HaasVocabularyMatcher.matchingKeys(of:)) ?? [])
        let updated = Set(HaasVocabularyMatcher.matchingKeys(
            writtenForm: existing?.writtenForm ?? form, readings: (existing?.readings ?? []) + [reading]))
        let added = updated.subtracting(current)
        // 同じ表記の語は照合で曖昧にならないので比べない
        let others = entries.filter { $0.id != existing?.id && $0.writtenForm != form }
        guard let collision = others.first(where: { !added.isDisjoint(with: HaasVocabularyMatcher.matchingKeys(of: $0)) })
        else { return nil }
        if HaasVocabularyMatcher.matchingKeys(of: collision).contains(key) {
            return "『\(form)』の読み『\(reading)』は『\(collision.writtenForm)』と同じなので登録しませんでした"
        }
        return "『\(form)』は『\(collision.writtenForm)』と同じ読みになるので登録しませんでした"
    }

    // MARK: - 履歴

    private func writeHistory(transcriptionID: UUID?, text: String) -> String? {
        guard let id = transcriptionID else { return nil }
        // 保存していない別の変更 (保存に失敗した録音の履歴など) があれば、巻き込まないように触れない
        guard !modelContext.hasChanges else { return Self.unsavedHistoryMessage }
        let request = FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == id })
        guard let rows = try? modelContext.fetch(request) else { return Self.historyFailedMessage }
        // 履歴が消されていれば、書き戻すものはない
        guard let row = rows.first else { return nil }
        row.enhancedText = text
        do {
            try modelContext.save()
            return nil
        } catch {
            // 直前に別の変更がないことを確かめてあるので、取り消すのは自分の変更だけ
            modelContext.rollback()
            logger.error("correction phase=history result=failed error=\(error.localizedDescription, privacy: .public)")
            return Self.historyFailedMessage
        }
    }
}
