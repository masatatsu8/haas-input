import SwiftData
import XCTest
@testable import VoiceInk

@MainActor
final class HaasCorrectionCoordinatorTests: XCTestCase {
    private let copiedMessage = "直した文をコピーしました。⌘V で貼れます"
    private let interruptedMessage = "入れ直しを途中で止めました。⌘V で直した文を貼れます"

    func testBeginReturnsNilWhileBusy() throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        fixture.deliver(text: "たつみです", field: FakeField(text: "たつみです"))
        fixture.idle = false
        XCTAssertNil(fixture.coordinator.begin())
        XCTAssertEqual(fixture.returnTarget.activateCount, 0)
    }

    func testBeginFallsBackToLatestHistoryWithoutRecord() throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        try fixture.addHistory(text: "古い文", timestamp: Date(timeIntervalSinceNow: -60))
        let latest = try fixture.addHistory(text: "新しい文", enhancedText: "新しい文。", timestamp: Date())

        let draft = try XCTUnwrap(fixture.coordinator.begin())
        XCTAssertEqual(draft.originalText, "新しい文。")
        XCTAssertEqual(draft.transcriptionID, latest.id)
        XCTAssertEqual(draft.decision, .copyOnly(.noRecord))
    }

    func testUnchangedTextTouchesNothing() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let row = try fixture.addHistory(text: "たつみです")
        fixture.deliver(text: "たつみです", field: FakeField(text: "たつみです"), transcriptionID: row.id)
        let draft = try XCTUnwrap(fixture.coordinator.begin())

        let outcome = await fixture.coordinator.confirm(
            draft, corrected: "たつみです", register: [newWord("巽", reading: "たつみ")])

        XCTAssertEqual(outcome, HaasCorrectionOutcome(result: .unchanged, dictionaryErrors: [], historyError: nil))
        XCTAssertTrue(fixture.replacer.calls.isEmpty)
        XCTAssertTrue(fixture.replacer.copies.isEmpty)
        XCTAssertTrue(fixture.settings.entries.isEmpty)
        XCTAssertNil(row.enhancedText)
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testAutomaticReplacementUpdatesHistoryAndRecord() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let row = try fixture.addHistory(text: "たつみです")
        let field = FakeField(text: "前の文。たつみです")
        fixture.deliver(text: "たつみです", field: field, transcriptionID: row.id)
        let draft = try XCTUnwrap(fixture.coordinator.begin())
        XCTAssertEqual(draft.decision, .replaceAutomatically(deleteCount: 5))

        let outcome = await fixture.coordinator.confirm(draft, corrected: "巽です", register: [])

        XCTAssertEqual(outcome, HaasCorrectionOutcome(result: .replaced, dictionaryErrors: [], historyError: nil))
        XCTAssertEqual(fixture.replacer.calls, [FakeReplacer.Call(text: "巽です", deleteCount: 5)])
        XCTAssertEqual(field.text, "前の文。巽です")
        let saved = try XCTUnwrap(fixture.fetchHistory(id: row.id))
        XCTAssertEqual(saved.enhancedText, "巽です")
        XCTAssertEqual(saved.text, "たつみです")
        XCTAssertFalse(fixture.context.hasChanges)

        // 置き換えた文が新しい「直前の入力」になり、続けて直せる
        let next = try XCTUnwrap(fixture.coordinator.begin())
        XCTAssertEqual(next.originalText, "巽です")
        XCTAssertEqual(next.transcriptionID, row.id)
        XCTAssertEqual(next.decision, .replaceAutomatically(deleteCount: 3))
    }

    func testCopyWhenDecisionDowngradesAtConfirm() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "たつみです")
        fixture.deliver(text: "たつみです", field: field)
        let draft = try XCTUnwrap(fixture.coordinator.begin())
        XCTAssertEqual(draft.decision, .replaceAutomatically(deleteCount: 5))
        fixture.watcher.userActed()

        let outcome = await fixture.coordinator.confirm(draft, corrected: "巽です", register: [])

        XCTAssertEqual(outcome.result, .copied(copiedMessage))
        XCTAssertTrue(fixture.replacer.calls.isEmpty)
        XCTAssertEqual(fixture.replacer.copies, ["巽です"])
        XCTAssertEqual(field.text, "たつみです")

        // 次に開くと直した文から始め、入力先の中身は直した文ではないのでコピーだけにする
        let next = try XCTUnwrap(fixture.coordinator.begin())
        XCTAssertEqual(next.originalText, "巽です")
        XCTAssertEqual(next.decision, .copyOnly(.alreadyCorrected))
    }

    func testInterruptedReplacementCopiesAndDisablesRetry() async throws {
        let outcomes: [HaasReplaceOutcome] = [
            .deletionInterrupted(deleted: 2), .deletionInterrupted(deleted: 0), .notStarted, .pasteUncertain,
        ]
        for replaceOutcome in outcomes {
            let fixture = try CorrectionFixture()
            defer { fixture.cleanUp() }
            fixture.replacer.forcedOutcome = replaceOutcome
            fixture.deliver(text: "たつみです", field: FakeField(text: "たつみです"))
            let draft = try XCTUnwrap(fixture.coordinator.begin())

            let outcome = await fixture.coordinator.confirm(draft, corrected: "巽です", register: [])

            XCTAssertEqual(outcome.result, .copied(interruptedMessage), "\(replaceOutcome)")
            XCTAssertEqual(fixture.replacer.calls.count, 1)
            // 置き換えの手順はクリップボードを元に戻すので、必ずコピーし直す
            XCTAssertEqual(fixture.replacer.copies, ["巽です"], "\(replaceOutcome)")
            // 欄は途中まで消えていて、履歴は直した文なので、直した文から始めてコピーだけにする
            let next = try XCTUnwrap(fixture.coordinator.begin())
            XCTAssertEqual(next.originalText, "巽です", "\(replaceOutcome)")
            XCTAssertEqual(next.decision, .copyOnly(.alreadyCorrected), "\(replaceOutcome)")
        }
    }

    func testRejectsEditedReadingThatCollides() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        try fixture.settings.saveEntry(writtenForm: "竜巳", readings: ["りゅうみ"], category: .person)
        fixture.deliver(text: "たつみです", field: nil)
        let draft = try XCTUnwrap(fixture.coordinator.begin())

        let outcome = await fixture.coordinator.confirm(
            draft, corrected: "巽です", register: [newWord("巽", reading: "りゅうみ")])

        XCTAssertEqual(outcome.dictionaryErrors, ["『巽』の読み『りゅうみ』は『竜巳』と同じなので登録しませんでした"])
        XCTAssertEqual(fixture.settings.entries.map(\.writtenForm), ["竜巳"])
    }

    func testRegistersOnlySelectedSuggestions() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        try fixture.settings.saveEntry(writtenForm: "早乙女", readings: ["さおとめ"], category: .person)
        let existing = try XCTUnwrap(fixture.settings.entries.first)
        fixture.deliver(text: "かつらぎとそうとめとはーす", field: nil)
        let draft = try XCTUnwrap(fixture.coordinator.begin())
        let selected = [
            newWord("葛城", reading: "かつらぎ"),
            HaasDictionarySuggestion(
                id: 1, kind: .addReading(entryID: existing.id), before: "そうとめ", writtenForm: "早乙女",
                reading: "そうとめ"),
            HaasDictionarySuggestion(id: 2, kind: .replacement, before: "はーす", writtenForm: "Haas", reading: ""),
        ]

        let outcome = await fixture.coordinator.confirm(
            draft, corrected: "葛城と早乙女とHaas", register: selected)

        XCTAssertEqual(outcome.dictionaryErrors, [])
        let entries = fixture.settings.entries
        XCTAssertEqual(entries.map(\.writtenForm), ["早乙女", "葛城"])
        XCTAssertEqual(entries[0].readings, ["さおとめ", "そうとめ"])
        XCTAssertEqual(entries[0].category, .person)
        XCTAssertEqual(entries[1].readings, ["かつらぎ"])
        XCTAssertEqual(entries[1].category, .other)
        let rules = try fixture.context.fetch(FetchDescriptor<WordReplacement>())
        XCTAssertEqual(rules.map(\.originalText), ["はーす"])
        XCTAssertEqual(rules.map(\.replacementText), ["Haas"])
    }

    func testDictionaryFailureDoesNotStopReplacement() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        try fixture.settings.saveEntry(writtenForm: "巽", readings: ["たつみ"], category: .person)
        fixture.deliver(text: "たつみです", field: FakeField(text: "たつみです"))
        let draft = try XCTUnwrap(fixture.coordinator.begin())

        let outcome = await fixture.coordinator.confirm(
            draft, corrected: "巽です", register: [newWord("巽", reading: "たつみ")])

        XCTAssertEqual(outcome.result, .replaced)
        XCTAssertEqual(outcome.dictionaryErrors.count, 1)
        XCTAssertEqual(fixture.settings.entries.count, 1)
    }

    func testEmptyCorrectionIsRejected() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let row = try fixture.addHistory(text: "たつみです")
        let field = FakeField(text: "たつみです")
        fixture.deliver(text: "たつみです", field: field, transcriptionID: row.id)
        let draft = try XCTUnwrap(fixture.coordinator.begin())

        let outcome = await fixture.coordinator.confirm(
            draft, corrected: " \n　", register: [newWord("巽", reading: "たつみ")])

        guard case .failed = outcome.result else { return XCTFail("空の文は確定しない: \(outcome.result)") }
        XCTAssertTrue(fixture.replacer.calls.isEmpty)
        XCTAssertTrue(fixture.replacer.copies.isEmpty)
        XCTAssertTrue(fixture.settings.entries.isEmpty)
        XCTAssertNil(row.enhancedText)
        XCTAssertEqual(field.text, "たつみです")
    }

    func testFieldChangeDuringDeletionStops() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "前の文。たつみです")
        // 1文字消した直後に、利用者が文字を選んだ状態にする
        field.selectAfterBackspaces = 1
        fixture.deliver(text: "たつみです", field: field)
        let draft = try XCTUnwrap(fixture.coordinator.begin())
        XCTAssertEqual(draft.decision, .replaceAutomatically(deleteCount: 5))

        let outcome = await fixture.coordinator.confirm(draft, corrected: "巽です", register: [])

        XCTAssertEqual(outcome.result, .copied(interruptedMessage))
        XCTAssertEqual(fixture.replacer.calls.count, 1)
        XCTAssertEqual(fixture.replacer.lastOutcome, .deletionInterrupted(deleted: 1))
        XCTAssertEqual(field.backspaces, 1)
        XCTAssertEqual(field.text, "前の文。たつみで")
        XCTAssertEqual(fixture.replacer.copies, ["巽です"])
    }

    func testFieldThatLagsBehindBackspaceIsReadAgain() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "前の文。たつみです")
        // Backspace の後、2回読むまでは前の中身を返す (ブラウザなど)
        field.staleReadsAfterBackspace = 2
        fixture.deliver(text: "たつみです", field: field)
        let draft = try XCTUnwrap(fixture.coordinator.begin())
        XCTAssertEqual(draft.decision, .replaceAutomatically(deleteCount: 5))

        let outcome = await fixture.coordinator.confirm(draft, corrected: "巽です", register: [])

        XCTAssertEqual(outcome.result, .replaced)
        XCTAssertEqual(field.backspaces, 5)
        XCTAssertEqual(field.text, "前の文。巽です")
    }

    func testFieldThatNeverCatchesUpStopsAfterWaiting() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "前の文。たつみです")
        field.staleReadsAfterBackspace = .max
        fixture.deliver(text: "たつみです", field: field)
        let draft = try XCTUnwrap(fixture.coordinator.begin())

        let outcome = await fixture.coordinator.confirm(draft, corrected: "巽です", register: [])

        XCTAssertEqual(outcome.result, .copied(interruptedMessage))
        XCTAssertEqual(fixture.replacer.lastOutcome, .deletionInterrupted(deleted: 1))
        XCTAssertEqual(field.backspaces, 1)
        XCTAssertEqual(fixture.replacer.copies, ["巽です"])
    }

    func testUnreadableTargetReplacesWithoutFieldCheck() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "たつみです")
        field.readable = false
        fixture.deliver(text: "たつみです", field: field)
        let draft = try XCTUnwrap(fixture.coordinator.begin())
        XCTAssertEqual(draft.decision, .replaceAfterConfirmation(deleteCount: 5))

        let outcome = await fixture.coordinator.confirm(draft, corrected: "巽です", register: [])

        XCTAssertEqual(outcome.result, .replaced)
        XCTAssertEqual(field.text, "巽です")
        XCTAssertEqual(fixture.focusWaits, 1)
    }

    func testFocusReturnsOnEveryPath() async throws {
        // 取り消し
        do {
            let fixture = try CorrectionFixture()
            defer { fixture.cleanUp() }
            fixture.deliver(text: "たつみです", field: FakeField(text: "たつみです"))
            XCTAssertNotNil(fixture.coordinator.begin())
            fixture.coordinator.cancel()
            XCTAssertEqual(fixture.returnTarget.activateCount, 1)
        }
        // 文を変えずに確定
        do {
            let fixture = try CorrectionFixture()
            defer { fixture.cleanUp() }
            fixture.deliver(text: "たつみです", field: FakeField(text: "たつみです"))
            let draft = try XCTUnwrap(fixture.coordinator.begin())
            _ = await fixture.coordinator.confirm(draft, corrected: "たつみです", register: [])
            XCTAssertEqual(fixture.returnTarget.activateCount, 1)
        }
        // コピーだけの確定
        do {
            let fixture = try CorrectionFixture()
            defer { fixture.cleanUp() }
            fixture.deliver(text: "たつみです", field: nil)
            let draft = try XCTUnwrap(fixture.coordinator.begin())
            let outcome = await fixture.coordinator.confirm(draft, corrected: "巽です", register: [])
            XCTAssertEqual(outcome.result, .copied(copiedMessage))
            XCTAssertEqual(fixture.returnTarget.activateCount, 1)
        }
        // 履歴の文で開いたとき
        do {
            let fixture = try CorrectionFixture()
            defer { fixture.cleanUp() }
            try fixture.addHistory(text: "たつみです")
            let draft = try XCTUnwrap(fixture.coordinator.begin())
            XCTAssertEqual(draft.decision, .copyOnly(.noRecord))
            _ = await fixture.coordinator.confirm(draft, corrected: "巽です", register: [])
            XCTAssertEqual(fixture.returnTarget.activateCount, 1)
        }
    }

    func testUnsavedHistoryIsNotTouched() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let row = try fixture.addHistory(text: "たつみです")
        fixture.deliver(text: "たつみです", field: FakeField(text: "たつみです"), transcriptionID: row.id)
        let draft = try XCTUnwrap(fixture.coordinator.begin())
        fixture.context.insert(Transcription(text: "保存に失敗した録音", duration: 1))
        XCTAssertTrue(fixture.context.hasChanges)

        let outcome = await fixture.coordinator.confirm(draft, corrected: "巽です", register: [])

        XCTAssertEqual(outcome.result, .replaced)
        XCTAssertEqual(outcome.dictionaryErrors, [])
        XCTAssertEqual(outcome.historyError, "履歴を書き換えられませんでした。保存されていない履歴があります")
        XCTAssertNil(row.enhancedText)
        XCTAssertTrue(fixture.context.hasChanges)
        let texts = try fixture.context.fetch(FetchDescriptor<Transcription>()).map(\.text)
        XCTAssertEqual(Set(texts), ["たつみです", "保存に失敗した録音"])
    }

    func testCopyFailureKeepsCorrectedText() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let row = try fixture.addHistory(text: "たつみです")
        fixture.replacer.copyResult = false
        fixture.deliver(text: "たつみです", field: nil, transcriptionID: row.id)
        let draft = try XCTUnwrap(fixture.coordinator.begin())

        let outcome = await fixture.coordinator.confirm(
            draft, corrected: "巽です", register: [newWord("巽", reading: "たつみ")])

        XCTAssertEqual(
            outcome.result, .failed("直した文をコピーできませんでした。もう一度開くと、直した文から始められます"))
        XCTAssertEqual(fixture.settings.entries.map(\.writtenForm), ["巽"])
        XCTAssertEqual(row.enhancedText, "巽です")
        let next = try XCTUnwrap(fixture.coordinator.begin())
        XCTAssertEqual(next.originalText, "巽です")
        XCTAssertEqual(next.decision, .copyOnly(.alreadyCorrected))
    }

    func testSameTextRetriesCopyAfterCopyFailure() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let row = try fixture.addHistory(text: "たつみです")
        fixture.replacer.copyResult = false
        fixture.deliver(text: "たつみです", field: nil, transcriptionID: row.id)
        let draft = try XCTUnwrap(fixture.coordinator.begin())
        _ = await fixture.coordinator.confirm(draft, corrected: "巽です", register: [newWord("巽", reading: "たつみ")])
        // 書き戻しをやり直さないことを確かめるため、履歴を別の文にしておく
        row.enhancedText = "履歴の画面で直した文"
        try fixture.context.save()

        fixture.replacer.copyResult = true
        let retry = try XCTUnwrap(fixture.coordinator.begin())
        let outcome = await fixture.coordinator.confirm(
            retry, corrected: "巽です", register: [newWord("巽", reading: "たつみ")])

        XCTAssertEqual(outcome, HaasCorrectionOutcome(result: .copied(copiedMessage), dictionaryErrors: [], historyError: nil))
        XCTAssertEqual(fixture.replacer.copies, ["巽です", "巽です"])
        XCTAssertTrue(fixture.replacer.calls.isEmpty)
        XCTAssertEqual(fixture.settings.entries.map(\.writtenForm), ["巽"])
        XCTAssertEqual(row.enhancedText, "履歴の画面で直した文")

        // コピーできた後は、同じ文の確定は何もしない
        let after = try XCTUnwrap(fixture.coordinator.begin())
        let unchanged = await fixture.coordinator.confirm(after, corrected: "巽です", register: [])
        XCTAssertEqual(unchanged.result, .unchanged)
        XCTAssertEqual(fixture.replacer.copies.count, 2)
    }

    func testMismatchedDraftStillReturnsFocusAndOnlyCopies() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        fixture.deliver(text: "たつみです", field: FakeField(text: "たつみです"))
        XCTAssertNotNil(fixture.coordinator.begin())
        let other = HaasCorrectionDraft(originalText: "別の文", transcriptionID: nil, decision: .replaceAutomatically(deleteCount: 3))

        let outcome = await fixture.coordinator.confirm(other, corrected: "巽です", register: [])

        XCTAssertEqual(fixture.returnTarget.activateCount, 1)
        XCTAssertTrue(fixture.replacer.calls.isEmpty)
        XCTAssertEqual(outcome.result, .copied(copiedMessage))
    }

    func testFailedBeginClearsPreviousSession() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "たつみです")
        fixture.deliver(text: "たつみです", field: field)
        let draft = try XCTUnwrap(fixture.coordinator.begin())
        fixture.idle = false
        XCTAssertNil(fixture.coordinator.begin())

        let outcome = await fixture.coordinator.confirm(draft, corrected: "巽です", register: [])

        // 古い状態では置き換えず、コピーだけにする
        XCTAssertTrue(fixture.replacer.calls.isEmpty)
        XCTAssertEqual(fixture.replacer.copies, ["巽です"])
        XCTAssertEqual(outcome.result, .copied(copiedMessage))
        XCTAssertEqual(field.text, "たつみです")
    }

    func testSuggestionsCompareWithShownText() throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        fixture.deliver(text: "たつみです", field: nil)
        XCTAssertNotNil(fixture.coordinator.begin())
        XCTAssertEqual(
            fixture.coordinator.suggestions(for: "巽です"),
            HaasCorrectionSuggester.suggestions(original: "たつみです", corrected: "巽です", entries: []))
    }

    private func newWord(_ form: String, reading: String) -> HaasDictionarySuggestion {
        HaasDictionarySuggestion(id: 0, kind: .newWord, before: reading, writtenForm: form, reading: reading)
    }
}

@MainActor
private final class CorrectionFixture {
    let suite: String
    let defaults: UserDefaults
    let settings: HaasSettingsStore
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let provider = FakeDeliveredInputProvider()
    let watcher = FakeCorrectionWatcher()
    let replacer = FakeReplacer()
    let returnTarget = FakeTarget(field: FakeField(text: ""))
    var idle = true
    private(set) var focusWaits = 0

    lazy var coordinator = HaasCorrectionCoordinator(
        delivery: provider, monitor: watcher, replacer: replacer, settings: settings, modelContext: context,
        isIdle: { [unowned self] in self.idle },
        captureReturnTarget: { [unowned self] in self.returnTarget },
        waitForFocus: { [unowned self] _ in self.focusWaits += 1 })

    init() throws {
        suite = "HaasCorrectionCoordinatorTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = HaasSettingsStore(defaults: defaults)
        let schema = Schema([Transcription.self, WordReplacement.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: configuration)
        container.mainContext.autosaveEnabled = false
    }

    /// 配信の記録を作る。field が nil なら入力先なし
    @discardableResult
    func deliver(text: String, field: FakeField?, posted: Bool = true, transcriptionID: UUID? = nil) -> FakeTarget? {
        let target = field.map { FakeTarget(field: $0) }
        replacer.field = field
        provider.lastDeliveredInput = HaasDeliveredInput(
            sessionID: UUID(), transcriptionID: transcriptionID, text: text, allSegmentsPosted: posted,
            target: target, watchToken: watcher.startWatching())
        return target
    }

    @discardableResult
    func addHistory(text: String, enhancedText: String? = nil, timestamp: Date = Date()) throws -> Transcription {
        let row = Transcription(text: text, duration: 1, enhancedText: enhancedText, transcriptionStatus: .completed)
        row.timestamp = timestamp
        context.insert(row)
        try context.save()
        return row
    }

    func fetchHistory(id: UUID) throws -> Transcription? {
        try context.fetch(FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == id })).first
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }
}

/// カーソルが末尾にある入力欄の偽物
@MainActor
private final class FakeField {
    var text: String
    var selectionLength = 0
    var readable = true
    var selectAfterBackspaces: Int?
    /// Backspace の後、この回数読むまでは前の中身を返す
    var staleReadsAfterBackspace = 0
    private(set) var backspaces = 0
    private var staleText: String?
    private var staleReadsLeft = 0

    init(text: String) { self.text = text }

    var state: HaasFieldState {
        guard readable else { return .unreadable }
        if let staleText, staleReadsLeft > 0 {
            staleReadsLeft -= 1
            return .readable(textBeforeCaret: staleText, selectionLength: selectionLength)
        }
        return .readable(textBeforeCaret: text, selectionLength: selectionLength)
    }

    func backspace() {
        if staleReadsAfterBackspace > 0 {
            staleText = text
            staleReadsLeft = staleReadsAfterBackspace
        }
        if !text.isEmpty { text.removeLast() }
        backspaces += 1
        if backspaces == selectAfterBackspaces { selectionLength = 1 }
    }
}

@MainActor
private final class FakeTarget: HaasInputTargetChecking {
    let diagnosticAppIdentifier = "test.target"
    let field: FakeField
    var rejection: String?
    private(set) var activateCount = 0

    init(field: FakeField) { self.field = field }

    func rejectionReason() -> String? { rejection }
    func fieldState() -> HaasFieldState { field.state }
    func activate() -> Bool {
        activateCount += 1
        return true
    }
}

@MainActor
private final class FakeDeliveredInputProvider: HaasDeliveredInputProviding {
    var lastDeliveredInput: HaasDeliveredInput?
}

@MainActor
private final class FakeCorrectionWatcher: HaasInputWatching {
    private var current: UUID?

    func startWatching() -> UUID {
        let token = UUID()
        current = token
        return token
    }

    func isClean(for token: UUID) -> Bool { token == current }
    func invalidate() { current = nil }
    func userActed() { current = nil }
}

/// 入力欄の偽物に Backspace と貼り付けを反映する置き換え役
@MainActor
private final class FakeReplacer: HaasCorrectionReplacing {
    struct Call: Equatable {
        let text: String
        let deleteCount: Int
    }

    /// Backspace と貼り付けを反映する入力欄
    var field: FakeField?
    var forcedOutcome: HaasReplaceOutcome?
    var copyResult = true
    private(set) var calls: [Call] = []
    private(set) var copies: [String] = []
    private(set) var lastOutcome: HaasReplaceOutcome?

    func replace(
        _ text: String, deleteCount: Int, shouldContinue: @escaping (_ deleted: Int) async -> Bool,
        pasteGuard: @escaping () -> Bool
    ) async -> HaasReplaceOutcome {
        calls.append(Call(text: text, deleteCount: deleteCount))
        let outcome: HaasReplaceOutcome
        if let forcedOutcome {
            outcome = forcedOutcome
        } else {
            outcome = await simulate(text, deleteCount: deleteCount, shouldContinue, pasteGuard)
        }
        lastOutcome = outcome
        return outcome
    }

    func copy(_ text: String) -> Bool {
        copies.append(text)
        return copyResult
    }

    /// CursorPaster.runReplacement と同じ順で確かめる
    private func simulate(
        _ text: String, deleteCount: Int, _ shouldContinue: (Int) async -> Bool, _ pasteGuard: () -> Bool
    ) async -> HaasReplaceOutcome {
        var deleted = 0
        while deleted < deleteCount {
            guard await shouldContinue(deleted) else { return deleted == 0 ? .notStarted : .deletionInterrupted(deleted: deleted) }
            field?.backspace()
            deleted += 1
        }
        guard await shouldContinue(deleted) else { return deleted == 0 ? .notStarted : .deletionInterrupted(deleted: deleted) }
        guard pasteGuard() else { return .pasteUncertain }
        field?.text += text
        return .completed
    }
}
