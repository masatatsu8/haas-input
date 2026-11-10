import SwiftData
import XCTest
@testable import VoiceInk

@MainActor
final class HaasCorrectionCoordinatorTests: XCTestCase {
    private let copiedMessage = "直した文をコピーしました。⌘V で貼れます"
    private let interruptedMessage = "入れ直しを途中で止めました。⌘V で直した文を貼れます"

    func testHotkeyDoesNothingWhileBusyButTellsWhenNothingToCorrect() throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        var notices: [String] = []
        let controller = HaasCorrectionPanelController(coordinator: fixture.coordinator) { message, _ in
            notices.append(message)
        }
        // 録音中・認識中は、直す文がなくても知らせない
        fixture.idle = false
        XCTAssertTrue(fixture.coordinator.isBusy)
        controller.show()
        XCTAssertEqual(notices, [])
        XCTAssertEqual(fixture.returnTarget.activateCount, 0)

        // 待機中に直す文がなければ知らせる。録音中に押した後も、次のホットキーは効く
        fixture.idle = true
        XCTAssertFalse(fixture.coordinator.isBusy)
        controller.show()
        XCTAssertEqual(notices, ["直す入力がありません"])

        // 直せる時間を過ぎた入力は、知らせずに何もしない
        fixture.deliver(text: "さいとうです", field: FakeField(text: "さいとうです"))
        fixture.now = fixture.now.addingTimeInterval(121)
        XCTAssertEqual(fixture.coordinator.begin(), .unavailable)
        controller.show()
        XCTAssertEqual(notices, ["直す入力がありません"])
        XCTAssertEqual(fixture.returnTarget.activateCount, 0)
        XCTAssertEqual(fixture.returnTargetCaptures, 0, "開けないときは前面のアプリに触れない")

        // 何もしなかった後も、次のホットキーは効く
        fixture.provider.lastDeliveredInput = nil
        controller.show()
        XCTAssertEqual(notices, ["直す入力がありません", "直す入力がありません"])
    }

    func testBeginIsUnavailableWhileBusy() throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        fixture.deliver(text: "さいとうです", field: FakeField(text: "さいとうです"))
        fixture.idle = false
        XCTAssertEqual(fixture.coordinator.begin(), .unavailable)
        XCTAssertEqual(fixture.returnTarget.activateCount, 0)
    }

    func testBeginFallsBackToLatestHistoryWithoutRecord() throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        try fixture.addHistory(text: "古い文", timestamp: Date(timeIntervalSinceNow: -60))
        let latest = try fixture.addHistory(text: "新しい文", enhancedText: "新しい文。", timestamp: Date())

        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(draft.originalText, "新しい文。")
        XCTAssertEqual(draft.transcriptionID, latest.id)
        XCTAssertEqual(draft.decision, .copyOnly(.noRecord))
    }

    func testUnchangedTextTouchesNothing() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let row = try fixture.addHistory(text: "さいとうです")
        fixture.deliver(text: "さいとうです", field: FakeField(text: "さいとうです"), transcriptionID: row.id)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)

        let outcome = await fixture.coordinator.confirm(
            draft, corrected: "さいとうです", register: [newWord("斎藤", reading: "さいとう")])

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
        let row = try fixture.addHistory(text: "さいとうです")
        let field = FakeField(text: "前の文。さいとうです")
        fixture.deliver(text: "さいとうです", field: field, transcriptionID: row.id)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(draft.decision, .replaceAutomatically(deleteCount: 6))

        let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])

        XCTAssertEqual(outcome, HaasCorrectionOutcome(result: .replaced, dictionaryErrors: [], historyError: nil))
        XCTAssertEqual(fixture.replacer.calls, [FakeReplacer.Call(text: "斎藤です", deleteCount: 6)])
        XCTAssertEqual(field.text, "前の文。斎藤です")
        let saved = try XCTUnwrap(fixture.fetchHistory(id: row.id))
        XCTAssertEqual(saved.enhancedText, "斎藤です")
        XCTAssertEqual(saved.text, "さいとうです")
        XCTAssertFalse(fixture.context.hasChanges)

        // 直し終えたので、同じ入力ではもう開かない
        XCTAssertEqual(fixture.coordinator.begin(), .unavailable)
    }

    func testCopyWhenDecisionDowngradesAtConfirm() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "さいとうです")
        fixture.deliver(text: "さいとうです", field: field)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(draft.decision, .replaceAutomatically(deleteCount: 6))
        fixture.watcher.userActed()

        let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])

        XCTAssertEqual(outcome.result, .copied(copiedMessage))
        XCTAssertTrue(fixture.replacer.calls.isEmpty)
        XCTAssertEqual(fixture.replacer.copies, ["斎藤です"])
        XCTAssertEqual(field.text, "さいとうです")

        // 直してコピーした後は、同じ入力ではもう開かない
        XCTAssertEqual(fixture.coordinator.begin(), .unavailable)
    }

    func testInterruptedReplacementCopiesAndDisablesRetry() async throws {
        let outcomes: [HaasReplaceOutcome] = [
            .deletionInterrupted(deleted: 2), .deletionInterrupted(deleted: 0), .notStarted, .pasteUncertain,
        ]
        for replaceOutcome in outcomes {
            let fixture = try CorrectionFixture()
            defer { fixture.cleanUp() }
            fixture.replacer.forcedOutcome = replaceOutcome
            fixture.deliver(text: "さいとうです", field: FakeField(text: "さいとうです"))
            let draft = try XCTUnwrap(fixture.coordinator.begin().draft)

            let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])

            XCTAssertEqual(outcome.result, .copied(interruptedMessage), "\(replaceOutcome)")
            XCTAssertEqual(fixture.replacer.calls.count, 1)
            // 置き換えの手順はクリップボードを元に戻すので、必ずコピーし直す
            XCTAssertEqual(fixture.replacer.copies, ["斎藤です"], "\(replaceOutcome)")
            // 途中で止めてコピーした後も、同じ入力ではもう開かない
            XCTAssertEqual(fixture.coordinator.begin(), .unavailable, "\(replaceOutcome)")
        }
    }

    func testRejectsEditedReadingThatCollides() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        try fixture.settings.saveEntry(writtenForm: "西藤", readings: ["にしふじ"], category: .person)
        fixture.deliver(text: "さいとうです", field: nil)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)

        let outcome = await fixture.coordinator.confirm(
            draft, corrected: "斎藤です", register: [newWord("斎藤", reading: "にしふじ")])

        XCTAssertEqual(outcome.dictionaryErrors, ["『斎藤』の読み『にしふじ』は『西藤』と同じなので登録しませんでした"])
        XCTAssertEqual(fixture.settings.entries.map(\.writtenForm), ["西藤"])
    }

    func testRejectsReadingThatCollidesWithKanaWrittenForm() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        // 読みのない「サイトウ」も、照合ではカナの正式表記を読み「さいとう」として使う
        try fixture.settings.saveEntry(writtenForm: "サイトウ", readings: [], category: .person)
        fixture.deliver(text: "斉藤です", field: nil)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)

        let outcome = await fixture.coordinator.confirm(
            draft, corrected: "斎藤です", register: [newWord("斎藤", reading: "さいとう")])

        XCTAssertEqual(outcome.dictionaryErrors, ["『斎藤』の読み『さいとう』は『サイトウ』と同じなので登録しませんでした"])
        XCTAssertEqual(fixture.settings.entries.map(\.writtenForm), ["サイトウ"])
    }

    func testRejectsNewKanaWrittenFormThatCollides() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        try fixture.settings.saveEntry(writtenForm: "斎藤", readings: ["さいとう"], category: .person)
        fixture.deliver(text: "東京です", field: nil)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)

        // 読み「とうきょう」はぶつからないが、正式表記「サイトウ」から増える読み「さいとう」がぶつかる
        let outcome = await fixture.coordinator.confirm(
            draft, corrected: "サイトウです",
            register: [HaasDictionarySuggestion(id: 0, kind: .newWord, before: "東京", writtenForm: "サイトウ", reading: "とうきょう")])

        XCTAssertEqual(outcome.dictionaryErrors, ["『サイトウ』は『斎藤』と同じ読みになるので登録しませんでした"])
        XCTAssertEqual(fixture.settings.entries.map(\.writtenForm), ["斎藤"])
    }

    func testAddReadingIsSkippedWhenEntryWasRenamed() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        try fixture.settings.saveEntry(writtenForm: "斎藤", readings: ["そん"], category: .person)
        let entry = try XCTUnwrap(fixture.settings.entries.first)
        fixture.deliver(text: "さいとうです", field: nil)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        let suggestion = HaasDictionarySuggestion(
            id: 0, kind: .addReading(entryID: entry.id), before: "さいとう", writtenForm: "斎藤", reading: "さいとう")
        // ポップアップを開いている間に、辞書の画面で同じ項目を改名した
        try fixture.settings.saveEntry(id: entry.id, writtenForm: "西藤", readings: ["そん"], category: .person)

        let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [suggestion])

        XCTAssertEqual(outcome.dictionaryErrors, ["『斎藤』は辞書で変更されたため、読みを追加しませんでした"])
        XCTAssertEqual(fixture.settings.entries.map(\.writtenForm), ["西藤"])
        XCTAssertEqual(fixture.settings.entries.first?.readings, ["そん"])
    }

    func testRegistersOnlySelectedSuggestions() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        try fixture.settings.saveEntry(writtenForm: "早乙女", readings: ["さおとめ"], category: .person)
        let existing = try XCTUnwrap(fixture.settings.entries.first)
        fixture.deliver(text: "かつらぎとそうとめとはーす", field: nil)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
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
        try fixture.settings.saveEntry(writtenForm: "斎藤", readings: ["さいとう"], category: .person)
        fixture.deliver(text: "さいとうです", field: FakeField(text: "さいとうです"))
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)

        let outcome = await fixture.coordinator.confirm(
            draft, corrected: "斎藤です", register: [newWord("斎藤", reading: "さいとう")])

        XCTAssertEqual(outcome.result, .replaced)
        XCTAssertEqual(outcome.dictionaryErrors.count, 1)
        XCTAssertEqual(fixture.settings.entries.count, 1)
    }

    func testEmptyCorrectionIsRejected() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let row = try fixture.addHistory(text: "さいとうです")
        let field = FakeField(text: "さいとうです")
        fixture.deliver(text: "さいとうです", field: field, transcriptionID: row.id)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)

        let outcome = await fixture.coordinator.confirm(
            draft, corrected: " \n　", register: [newWord("斎藤", reading: "さいとう")])

        guard case .failed = outcome.result else { return XCTFail("空の文は確定しない: \(outcome.result)") }
        XCTAssertTrue(fixture.replacer.calls.isEmpty)
        XCTAssertTrue(fixture.replacer.copies.isEmpty)
        XCTAssertTrue(fixture.settings.entries.isEmpty)
        XCTAssertNil(row.enhancedText)
        XCTAssertEqual(field.text, "さいとうです")
    }

    func testFieldChangeDuringDeletionStops() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "前の文。さいとうです")
        // 1文字消した直後に、利用者が文字を選んだ状態にする
        field.selectAfterBackspaces = 1
        fixture.deliver(text: "さいとうです", field: field)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(draft.decision, .replaceAutomatically(deleteCount: 6))

        let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])

        XCTAssertEqual(outcome.result, .copied(interruptedMessage))
        XCTAssertEqual(fixture.replacer.calls.count, 1)
        XCTAssertEqual(fixture.replacer.lastOutcome, .deletionInterrupted(deleted: 1))
        XCTAssertEqual(field.backspaces, 1)
        XCTAssertEqual(field.text, "前の文。さいとうで")
        XCTAssertEqual(fixture.replacer.copies, ["斎藤です"])
    }

    func testFieldThatLagsBehindBackspaceIsReadAgain() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "前の文。さいとうです")
        // Backspace の後、2回読むまでは前の中身を返す (ブラウザなど)
        field.staleReadsAfterBackspace = 2
        fixture.deliver(text: "さいとうです", field: field)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(draft.decision, .replaceAutomatically(deleteCount: 6))

        let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])

        XCTAssertEqual(outcome.result, .replaced)
        XCTAssertEqual(field.backspaces, 6)
        XCTAssertEqual(field.text, "前の文。斎藤です")
    }

    func testFieldThatNeverCatchesUpStopsAfterWaiting() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "前の文。さいとうです")
        field.staleReadsAfterBackspace = .max
        fixture.deliver(text: "さいとうです", field: field)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)

        let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])

        XCTAssertEqual(outcome.result, .copied(interruptedMessage))
        XCTAssertEqual(fixture.replacer.lastOutcome, .deletionInterrupted(deleted: 1))
        XCTAssertEqual(field.backspaces, 1)
        XCTAssertEqual(fixture.replacer.copies, ["斎藤です"])
    }

    func testIgnoredPasteIntoFieldEndingWithSameTextOnlyCopies() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        // 文字数の上限で貼り付けが無視され、欄は元から「はい」で終わっている
        let field = FakeField(text: "はい")
        fixture.deliver(text: "はい", field: field, baseline: .some(.readable(textBeforeInsertion: "はい", textAfterInsertion: "")))
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(draft.decision, .copyOnly(.textMismatch))

        let outcome = await fixture.coordinator.confirm(draft, corrected: "いいえ", register: [])

        XCTAssertEqual(outcome.result, .copied(copiedMessage))
        XCTAssertTrue(fixture.replacer.calls.isEmpty)
        XCTAssertEqual(field.text, "はい")
    }

    func testCaretMovedPastExistingSameTextOnlyCopies() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        // 貼る前は「前|はい後」。貼り付けが拒まれ、カーソルだけが「前はい|後」へ動いた
        let field = FakeField(text: "前はい", after: "後")
        fixture.deliver(
            text: "はい", field: field, baseline: .some(.readable(textBeforeInsertion: "前", textAfterInsertion: "はい後")))
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(draft.decision, .copyOnly(.textMismatch))

        let outcome = await fixture.coordinator.confirm(draft, corrected: "いいえ", register: [])

        XCTAssertEqual(outcome.result, .copied(copiedMessage))
        XCTAssertTrue(fixture.replacer.calls.isEmpty)
        XCTAssertEqual(field.backspaces, 0)
        XCTAssertEqual(field.text, "前はい")
        XCTAssertEqual(field.after, "後")
    }

    func testInsertionMergedWithPreviousCharacterOnlyCopies() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        // 前からある「か」に、結合の濁点で始まる「゙です」が入り、欄では「がです」になった
        let inserted = "\u{3099}です"
        let field = FakeField(text: "か" + inserted)
        fixture.deliver(
            text: inserted, field: field, baseline: .some(.readable(textBeforeInsertion: "か", textAfterInsertion: "")))
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(draft.decision, .copyOnly(.characterBoundary))

        let outcome = await fixture.coordinator.confirm(draft, corrected: "です", register: [])

        XCTAssertEqual(outcome.result, .copied(copiedMessage))
        XCTAssertTrue(fixture.replacer.calls.isEmpty)
        XCTAssertEqual(field.backspaces, 0)
        XCTAssertEqual(field.text, "か" + inserted)
    }

    func testUnreadableInsertionStartingWithCombiningMarkOnlyCopies() throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "か\u{3099}です")
        field.readable = false
        fixture.deliver(text: "\u{3099}です", field: field)
        XCTAssertEqual(fixture.coordinator.begin().draft?.decision, .copyOnly(.characterBoundary))
    }

    func testReplacementStartingWithCombiningMarkIsNotReopened() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "かさいとう")
        fixture.deliver(
            text: "さいとう", field: field, baseline: .some(.readable(textBeforeInsertion: "か", textAfterInsertion: "")))
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(draft.decision, .replaceAutomatically(deleteCount: 4))

        // 直した文が結合の濁点で始まり、前の「か」とつながって「がです」になる
        let corrected = "\u{3099}です"
        let outcome = await fixture.coordinator.confirm(draft, corrected: corrected, register: [])
        XCTAssertEqual(outcome.result, .replaced)
        XCTAssertEqual(field.text, "か" + corrected)

        // 直し終えたので開かない。「か」とつながった直した文を、続けて消すことはない
        XCTAssertEqual(fixture.coordinator.begin(), .unavailable)
    }

    func testReadableFieldWithoutInsertionRecordOnlyCopies() throws {
        for baseline in [HaasInsertionBaseline?.none, .unreadable] {
            let fixture = try CorrectionFixture()
            defer { fixture.cleanUp() }
            fixture.deliver(text: "さいとうです", field: FakeField(text: "前の文。さいとうです"), baseline: baseline)
            XCTAssertEqual(fixture.coordinator.begin().draft?.decision, .copyOnly(.insertionUnverified), "\(String(describing: baseline))")
        }
    }

    func testTextAfterCaretChangeDuringDeletionStops() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "前の文。さいとうです", after: "続き")
        // 1回目の Backspace で、カーソルの後ろの文字まで消える
        field.alsoDeleteAfterAtBackspace = 1
        fixture.deliver(text: "さいとうです", field: field)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(draft.decision, .replaceAutomatically(deleteCount: 6))

        let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])

        XCTAssertEqual(outcome.result, .copied(interruptedMessage))
        XCTAssertEqual(fixture.replacer.lastOutcome, .deletionInterrupted(deleted: 1))
        XCTAssertEqual(field.backspaces, 1)
        XCTAssertEqual(fixture.replacer.copies, ["斎藤です"])
    }

    func testStopsBeforeBackspaceThatWouldDeleteClosingPair() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        // 既存の「)」の直前に「(あ」を入れた。「(」を消すと、エディタが「)」も一緒に消す
        let field = FakeField(text: "前の文。(あ", after: ")")
        field.deletesClosingPair = true
        fixture.deliver(text: "(あ", field: field)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(draft.decision, .replaceAutomatically(deleteCount: 2))

        let outcome = await fixture.coordinator.confirm(draft, corrected: "(い", register: [])

        XCTAssertEqual(outcome.result, .copied(interruptedMessage))
        XCTAssertEqual(fixture.replacer.lastOutcome, .deletionInterrupted(deleted: 1))
        // 「あ」だけ消して、「(」の Backspace は送らない
        XCTAssertEqual(field.backspaces, 1)
        XCTAssertEqual(field.text, "前の文。(")
        XCTAssertEqual(field.after, ")")
    }

    func testSelectionChangeAfterCommandDownDoesNotPaste() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "前の文。さいとうです")
        fixture.deliver(text: "さいとうです", field: field)
        // ⌘ を押した後、入力先の遅れた処理が既存の文を選ぶ
        fixture.replacer.onCommandDown = { field.selectionLength = 1 }
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)

        let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])

        XCTAssertEqual(fixture.replacer.lastOutcome, .pasteUncertain)
        XCTAssertEqual(field.pastes, 0)
        XCTAssertEqual(field.text, "前の文。")
        XCTAssertEqual(outcome.result, .copied(interruptedMessage))
    }

    func testUnreadableTargetReplacesWithoutFieldCheck() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "さいとうです")
        field.readable = false
        fixture.deliver(text: "さいとうです", field: field)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(draft.decision, .replaceAfterConfirmation(deleteCount: 6))

        let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])

        XCTAssertEqual(outcome.result, .replaced)
        XCTAssertEqual(field.text, "斎藤です")
        XCTAssertEqual(fixture.focusWaits, 1)
    }

    func testFocusReturnsOnEveryPath() async throws {
        // 取り消し
        do {
            let fixture = try CorrectionFixture()
            defer { fixture.cleanUp() }
            fixture.deliver(text: "さいとうです", field: FakeField(text: "さいとうです"))
            XCTAssertNotNil(fixture.coordinator.begin().draft)
            fixture.coordinator.cancel()
            XCTAssertEqual(fixture.returnTarget.activateCount, 1)
        }
        // 文を変えずに確定
        do {
            let fixture = try CorrectionFixture()
            defer { fixture.cleanUp() }
            fixture.deliver(text: "さいとうです", field: FakeField(text: "さいとうです"))
            let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
            _ = await fixture.coordinator.confirm(draft, corrected: "さいとうです", register: [])
            XCTAssertEqual(fixture.returnTarget.activateCount, 1)
        }
        // コピーだけの確定
        do {
            let fixture = try CorrectionFixture()
            defer { fixture.cleanUp() }
            fixture.deliver(text: "さいとうです", field: nil)
            let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
            let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])
            XCTAssertEqual(outcome.result, .copied(copiedMessage))
            XCTAssertEqual(fixture.returnTarget.activateCount, 1)
        }
        // 履歴の文で開いたとき
        do {
            let fixture = try CorrectionFixture()
            defer { fixture.cleanUp() }
            try fixture.addHistory(text: "さいとうです")
            let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
            XCTAssertEqual(draft.decision, .copyOnly(.noRecord))
            _ = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])
            XCTAssertEqual(fixture.returnTarget.activateCount, 1)
        }
    }

    func testUnsavedHistoryIsNotTouched() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let row = try fixture.addHistory(text: "さいとうです")
        fixture.deliver(text: "さいとうです", field: FakeField(text: "さいとうです"), transcriptionID: row.id)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        fixture.context.insert(Transcription(text: "保存に失敗した録音", duration: 1))
        XCTAssertTrue(fixture.context.hasChanges)

        let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])

        XCTAssertEqual(outcome.result, .replaced)
        XCTAssertEqual(outcome.dictionaryErrors, [])
        XCTAssertEqual(outcome.historyError, "履歴を書き換えられませんでした。保存されていない履歴があります")
        XCTAssertNil(row.enhancedText)
        XCTAssertTrue(fixture.context.hasChanges)
        let texts = try fixture.context.fetch(FetchDescriptor<Transcription>()).map(\.text)
        XCTAssertEqual(Set(texts), ["さいとうです", "保存に失敗した録音"])
    }

    func testCopyFailureKeepsCorrectedText() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let row = try fixture.addHistory(text: "さいとうです")
        fixture.replacer.copyResult = false
        fixture.deliver(text: "さいとうです", field: nil, transcriptionID: row.id)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)

        let outcome = await fixture.coordinator.confirm(
            draft, corrected: "斎藤です", register: [newWord("斎藤", reading: "さいとう")])

        XCTAssertEqual(
            outcome.result, .failed("直した文をコピーできませんでした。もう一度開くと、直した文から始められます"))
        XCTAssertEqual(fixture.settings.entries.map(\.writtenForm), ["斎藤"])
        XCTAssertEqual(row.enhancedText, "斎藤です")
        // コピーできなかった直した文は、直せる時間を過ぎても直した文から始められる
        fixture.now = fixture.now.addingTimeInterval(600)
        let next = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(next.originalText, "斎藤です")
        XCTAssertEqual(next.decision, .copyOnly(.alreadyCorrected))
    }

    func testHistoryCopyFailureKeepsCorrectedTextAfterRowIsDeleted() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let row = try fixture.addHistory(text: "さいとうです")
        fixture.replacer.copyResult = false
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(draft.decision, .copyOnly(.noRecord))
        let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])
        XCTAssertEqual(outcome.result, .failed(HaasCorrectionCoordinator.copyFailedMessage))

        // 履歴の行を消し、直せる時間も過ぎた。それでも直した文からコピーをやり直せる
        fixture.context.delete(row)
        try fixture.context.save()
        fixture.now = fixture.now.addingTimeInterval(600)
        let retry = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(retry.originalText, "斎藤です")
        XCTAssertEqual(retry.decision, .copyOnly(.alreadyCorrected))

        fixture.replacer.copyResult = true
        let copied = await fixture.coordinator.confirm(retry, corrected: "斎藤です", register: [])
        XCTAssertEqual(copied.result, .copied(copiedMessage))
        XCTAssertEqual(fixture.coordinator.begin(), .nothingToCorrect)
    }

    func testSameTextRetriesCopyAfterCopyFailure() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let row = try fixture.addHistory(text: "さいとうです")
        fixture.replacer.copyResult = false
        fixture.deliver(text: "さいとうです", field: nil, transcriptionID: row.id)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        _ = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [newWord("斎藤", reading: "さいとう")])
        // 書き戻しをやり直さないことを確かめるため、履歴を別の文にしておく
        row.enhancedText = "履歴の画面で直した文"
        try fixture.context.save()

        fixture.replacer.copyResult = true
        let retry = try XCTUnwrap(fixture.coordinator.begin().draft)
        let outcome = await fixture.coordinator.confirm(
            retry, corrected: "斎藤です", register: [newWord("斎藤", reading: "さいとう")])

        XCTAssertEqual(outcome, HaasCorrectionOutcome(result: .copied(copiedMessage), dictionaryErrors: [], historyError: nil))
        XCTAssertEqual(fixture.replacer.copies, ["斎藤です", "斎藤です"])
        XCTAssertTrue(fixture.replacer.calls.isEmpty)
        XCTAssertEqual(fixture.settings.entries.map(\.writtenForm), ["斎藤"])
        XCTAssertEqual(row.enhancedText, "履歴の画面で直した文")

        // コピーできた後は、同じ入力ではもう開かない
        XCTAssertEqual(fixture.coordinator.begin(), .unavailable)
        XCTAssertEqual(fixture.replacer.copies.count, 2)
    }

    func testMismatchedDraftStillReturnsFocusAndOnlyCopies() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        fixture.deliver(text: "さいとうです", field: FakeField(text: "さいとうです"))
        XCTAssertNotNil(fixture.coordinator.begin().draft)
        let other = HaasCorrectionDraft(originalText: "別の文", transcriptionID: nil, decision: .replaceAutomatically(deleteCount: 3))

        let outcome = await fixture.coordinator.confirm(other, corrected: "斎藤です", register: [])

        XCTAssertEqual(fixture.returnTarget.activateCount, 1)
        XCTAssertTrue(fixture.replacer.calls.isEmpty)
        XCTAssertEqual(outcome.result, .copied(copiedMessage))
    }

    func testFailedBeginClearsPreviousSession() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "さいとうです")
        fixture.deliver(text: "さいとうです", field: field)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        fixture.idle = false
        XCTAssertEqual(fixture.coordinator.begin(), .unavailable)

        let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])

        // 古い状態では置き換えず、コピーだけにする
        XCTAssertTrue(fixture.replacer.calls.isEmpty)
        XCTAssertEqual(fixture.replacer.copies, ["斎藤です"])
        XCTAssertEqual(outcome.result, .copied(copiedMessage))
        XCTAssertEqual(field.text, "さいとうです")
    }

    func testSuggestionsCompareWithShownText() throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        fixture.deliver(text: "さいとうです", field: nil)
        XCTAssertNotNil(fixture.coordinator.begin().draft)
        XCTAssertEqual(
            fixture.coordinator.suggestions(for: "斎藤です"),
            HaasCorrectionSuggester.suggestions(original: "さいとうです", corrected: "斎藤です", entries: []))
    }

    func testUnchangedEmptyOrCancelledCorrectionCanReopen() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        fixture.deliver(text: "さいとうです", field: FakeField(text: "さいとうです"))

        let first = try XCTUnwrap(fixture.coordinator.begin().draft)
        let unchanged = await fixture.coordinator.confirm(first, corrected: "さいとうです", register: [])
        XCTAssertEqual(unchanged.result, .unchanged)

        let second = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(second, first)
        let empty = await fixture.coordinator.confirm(second, corrected: " ", register: [])
        XCTAssertEqual(empty.result, .failed(HaasCorrectionCoordinator.emptyMessage))

        XCTAssertEqual(fixture.coordinator.begin().draft, first)
        fixture.coordinator.cancel()

        XCTAssertEqual(fixture.coordinator.begin().draft, first)
    }

    func testTimeLimitIsCheckedOnlyWhenOpening() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        let field = FakeField(text: "さいとうです")
        fixture.deliver(text: "さいとうです", field: field)

        // 既定は 120 秒。ちょうどなら開ける
        fixture.now = fixture.now.addingTimeInterval(120)
        XCTAssertNotNil(fixture.coordinator.begin().draft)
        fixture.coordinator.cancel()
        // 1 秒でも過ぎたら開かない
        fixture.now = fixture.now.addingTimeInterval(1)
        XCTAssertEqual(fixture.coordinator.begin(), .unavailable)

        // 設定で延ばせば開ける。開いた後に時間が過ぎても、確定はそのまま行う
        fixture.defaults.set(300, forKey: HaasCorrectionSettingsKeys.timeLimitSeconds)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        fixture.now = fixture.now.addingTimeInterval(600)
        let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])
        XCTAssertEqual(outcome.result, .replaced)
        XCTAssertEqual(field.text, "斎藤です")
    }

    func testNewRecordingAfterClosingCanBeCorrected() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        fixture.deliver(text: "さいとうです", field: nil)
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        let outcome = await fixture.coordinator.confirm(draft, corrected: "斎藤です", register: [])
        XCTAssertEqual(outcome.result, .copied(copiedMessage))
        XCTAssertEqual(fixture.coordinator.begin(), .unavailable)

        fixture.deliver(text: "とうきょうです", field: nil)
        let next = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(next.originalText, "とうきょうです")
    }

    func testHistoryRowPastTimeLimitOrCorrectedIsUnavailable() async throws {
        let fixture = try CorrectionFixture()
        defer { fixture.cleanUp() }
        try fixture.addHistory(text: "古い文", timestamp: fixture.now.addingTimeInterval(-121))
        XCTAssertEqual(fixture.coordinator.begin(), .unavailable)

        let latest = try fixture.addHistory(text: "新しい文", timestamp: fixture.now.addingTimeInterval(-120))
        let draft = try XCTUnwrap(fixture.coordinator.begin().draft)
        XCTAssertEqual(draft.transcriptionID, latest.id)
        let outcome = await fixture.coordinator.confirm(draft, corrected: "新しい文。", register: [])
        XCTAssertEqual(outcome.result, .copied(copiedMessage))

        // 直してコピーした行は、直せる時間の内でも開かない
        XCTAssertEqual(fixture.coordinator.begin(), .unavailable)
    }

    func testStoredTimeLimitFallsBackToDefault() throws {
        let suite = "HaasCorrectionTimeLimitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = HaasCorrectionSettingsKeys.timeLimitSeconds

        XCTAssertEqual(HaasCorrectionCoordinator.storedTimeLimit(in: defaults), 120)
        defaults.set(0, forKey: key)
        XCTAssertEqual(HaasCorrectionCoordinator.storedTimeLimit(in: defaults), 120)
        defaults.set(-30, forKey: key)
        XCTAssertEqual(HaasCorrectionCoordinator.storedTimeLimit(in: defaults), 120)
        defaults.set(300, forKey: key)
        XCTAssertEqual(HaasCorrectionCoordinator.storedTimeLimit(in: defaults), 300)
    }

    private func newWord(_ form: String, reading: String) -> HaasDictionarySuggestion {
        HaasDictionarySuggestion(id: 0, kind: .newWord, before: reading, writtenForm: form, reading: reading)
    }
}

extension HaasCorrectionStart {
    /// .ready なら、その draft
    var draft: HaasCorrectionDraft? {
        guard case let .ready(draft) = self else { return nil }
        return draft
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
    /// coordinator が見る今の時刻。deliver と addHistory の既定の時刻にも使う
    var now = Date()
    private(set) var focusWaits = 0
    private(set) var returnTargetCaptures = 0

    lazy var coordinator = HaasCorrectionCoordinator(
        delivery: provider, monitor: watcher, replacer: replacer, settings: settings, modelContext: context,
        isIdle: { [unowned self] in self.idle },
        captureReturnTarget: { [unowned self] in
            self.returnTargetCaptures += 1
            return self.returnTarget
        },
        waitForFocus: { [unowned self] _ in self.focusWaits += 1 },
        now: { [unowned self] in self.now },
        timeLimit: { [unowned self] in HaasCorrectionCoordinator.storedTimeLimit(in: self.defaults) })

    init() throws {
        suite = "HaasCorrectionCoordinatorTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = HaasSettingsStore(defaults: defaults)
        let schema = Schema([Transcription.self, WordReplacement.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: configuration)
        container.mainContext.autosaveEnabled = false
    }

    /// 配信の記録を作る。入力し終えた時刻は now。field が nil なら入力先なし。
    /// baseline を渡さなければ、今の欄から入れた文を除いたものを、貼る前の欄として記録する
    @discardableResult
    func deliver(
        text: String, field: FakeField?, posted: Bool = true, transcriptionID: UUID? = nil,
        baseline: HaasInsertionBaseline?? = .none
    ) -> FakeTarget? {
        let target = field.map { FakeTarget(field: $0) }
        replacer.field = field
        let recorded: HaasInsertionBaseline?
        if let baseline {
            recorded = baseline
        } else if let field {
            recorded = field.readable
                ? .readable(textBeforeInsertion: String(field.text.dropLast(text.count)), textAfterInsertion: field.after)
                : .unreadable
        } else {
            recorded = nil
        }
        provider.lastDeliveredInput = HaasDeliveredInput(
            sessionID: UUID(), transcriptionID: transcriptionID, text: text, allSegmentsPosted: posted,
            target: target, watchToken: watcher.startWatching(), insertionBaseline: recorded, deliveredAt: now)
        return target
    }

    @discardableResult
    func addHistory(text: String, enhancedText: String? = nil, timestamp: Date? = nil) throws -> Transcription {
        let row = Transcription(text: text, duration: 1, enhancedText: enhancedText, transcriptionStatus: .completed)
        row.timestamp = timestamp ?? now
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

/// 入力欄の偽物。text はカーソルの前、after はカーソルの後ろ
@MainActor
private final class FakeField {
    var text: String
    var after: String
    var selectionLength = 0
    var readable = true
    var selectAfterBackspaces: Int?
    /// この回の Backspace で、カーソルの後ろの1文字も消える
    var alsoDeleteAfterAtBackspace: Int?
    /// 開き括弧を消すとき、直後の閉じ括弧も消す (VS Code の対の削除)
    var deletesClosingPair = false
    /// Backspace の後、この回数読むまでは前の中身を返す
    var staleReadsAfterBackspace = 0
    private(set) var backspaces = 0
    private(set) var pastes = 0
    private var staleText: String?
    private var staleReadsLeft = 0

    init(text: String, after: String = "") {
        self.text = text
        self.after = after
    }

    var state: HaasFieldState {
        guard readable else { return .unreadable }
        if let staleText, staleReadsLeft > 0 {
            staleReadsLeft -= 1
            return .readable(textBeforeCaret: staleText, textAfterCaret: after, selectionLength: selectionLength)
        }
        return .readable(textBeforeCaret: text, textAfterCaret: after, selectionLength: selectionLength)
    }

    func backspace() {
        if staleReadsAfterBackspace > 0 {
            staleText = text
            staleReadsLeft = staleReadsAfterBackspace
        }
        if deletesClosingPair, let last = text.last,
            let closing = HaasReplacementDecision.closingPairs[last], after.first == closing
        {
            after.removeFirst()
        }
        if !text.isEmpty { text.removeLast() }
        backspaces += 1
        if backspaces == alsoDeleteAfterAtBackspace, !after.isEmpty { after.removeFirst() }
        if backspaces == selectAfterBackspaces { selectionLength = 1 }
    }

    func paste(_ pasted: String) {
        text += pasted
        selectionLength = 0
        pastes += 1
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

/// 入力欄の偽物に Backspace と貼り付けを反映する置き換え役。手順は CursorPaster の本物を使う
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
    /// ⌘ を押した直後 (V を押す前) に起きること
    var onCommandDown: (() -> Void)?
    private(set) var calls: [Call] = []
    private(set) var copies: [String] = []
    private(set) var lastOutcome: HaasReplaceOutcome?

    func replace(
        _ text: String, deleteCount: Int,
        awaitField: @escaping @MainActor (_ deleted: Int) async -> Bool,
        shouldContinue: @escaping @MainActor (_ deleted: Int) -> Bool,
        pasteGuard: @escaping @MainActor (CursorPaster.PastePhase) -> Bool
    ) async -> HaasReplaceOutcome {
        calls.append(Call(text: text, deleteCount: deleteCount))
        let outcome: HaasReplaceOutcome
        if let forcedOutcome {
            outcome = forcedOutcome
        } else {
            let field = self.field
            let onCommandDown = self.onCommandDown
            outcome = await CursorPaster.runReplacement(
                deleteCount: deleteCount, awaitField: awaitField, shouldContinue: shouldContinue,
                postBackspaceDown: {
                    field?.backspace()
                    return true
                },
                paste: {
                    await CursorPaster.runPasteCommand(
                        pasteRejection: { pasteGuard($0) ? nil : .commandNotPosted },
                        post: { key in
                            switch key {
                            case .commandDown: onCommandDown?()
                            case .vDown: field?.paste(text)
                            case .vUp, .commandUp: break
                            }
                        })
                })
        }
        lastOutcome = outcome
        return outcome
    }

    func copy(_ text: String) -> Bool {
        copies.append(text)
        return copyResult
    }
}
