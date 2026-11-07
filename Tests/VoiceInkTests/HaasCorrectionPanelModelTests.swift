import XCTest
@testable import VoiceInk

@MainActor
final class HaasCorrectionPanelModelTests: XCTestCase {
    private func draft(_ decision: HaasReplacementDecision, text: String = "辰巳商事です") -> HaasCorrectionDraft {
        HaasCorrectionDraft(originalText: text, transcriptionID: nil, decision: decision)
    }

    private func suggestion(_ id: Int, before: String, written: String) -> HaasDictionarySuggestion {
        HaasDictionarySuggestion(id: id, kind: .replacement, before: before, writtenForm: written, reading: "")
    }

    func testPrimaryButtonTitleFollowsDecision() {
        let none = { (_: String) in HaasSuggestionResult(suggestions: [], usedDictionaryForms: []) }
        XCTAssertEqual(
            HaasCorrectionPanelModel(draft: draft(.replaceAutomatically(deleteCount: 3)), suggest: none)
                .primaryButtonTitle, "直して入力")
        XCTAssertEqual(
            HaasCorrectionPanelModel(draft: draft(.replaceAfterConfirmation(deleteCount: 7)), suggest: none)
                .primaryButtonTitle, "前の7文字を消して入れ直す")
        for reason in [HaasCopyReason.noRecord, .multiline, .alreadyCorrected] {
            XCTAssertEqual(
                HaasCorrectionPanelModel(draft: draft(.copyOnly(reason)), suggest: none).primaryButtonTitle,
                "直してコピー")
        }
    }

    func testCannotConfirmWhenBlank() {
        let none = { (_: String) in HaasSuggestionResult(suggestions: [], usedDictionaryForms: []) }
        let model = HaasCorrectionPanelModel(draft: draft(.copyOnly(.noRecord)), suggest: none)
        XCTAssertTrue(model.canConfirm)
        model.corrected = " \n　"
        XCTAssertFalse(model.canConfirm)
        model.corrected = "あ"
        XCTAssertTrue(model.canConfirm)
    }

    func testEditingRebuildsSuggestionsAndKeepsOnlyMatchingSelection() {
        var shown: [String: [HaasDictionarySuggestion]] = [
            "A": [suggestion(0, before: "a", written: "A"), suggestion(1, before: "b", written: "B")],
            "B": [suggestion(0, before: "b", written: "B"), suggestion(1, before: "c", written: "C")],
        ]
        let model = HaasCorrectionPanelModel(draft: draft(.copyOnly(.noRecord))) { corrected in
            HaasSuggestionResult(suggestions: shown[corrected] ?? [], usedDictionaryForms: [])
        }
        model.corrected = "A"
        XCTAssertEqual(model.suggestions.count, 2)
        XCTAssertTrue(model.selectedIDs.isEmpty)
        model.selectedIDs = [0, 1]
        model.corrected = "B"
        // 同じ before と writtenForm を持つのは b→B だけ。id は 1 から 0 へ変わる
        XCTAssertEqual(model.selectedIDs, [0])
        XCTAssertEqual(model.selectedSuggestions.map(\.before), ["b"])
        shown["B"] = []
        model.corrected = "B "
        model.corrected = "B"
        XCTAssertTrue(model.selectedIDs.isEmpty)
    }

    func testReadingEditSurvivesRebuildOfSameSuggestion() {
        let model = HaasCorrectionPanelModel(draft: draft(.copyOnly(.noRecord))) { _ in
            HaasSuggestionResult(
                suggestions: [
                    HaasDictionarySuggestion(id: 0, kind: .newWord, before: "a", writtenForm: "A", reading: "えー")
                ], usedDictionaryForms: [])
        }
        model.corrected = "x"
        model.setReading("びー", for: 0)
        XCTAssertEqual(model.suggestions.first?.reading, "びー")
        model.corrected = "xy"
        XCTAssertEqual(model.suggestions.first?.reading, "びー")
    }

    func testNoticeMentionsUsedDictionaryForms() {
        let model = HaasCorrectionPanelModel(draft: draft(.copyOnly(.noRecord))) { _ in
            HaasSuggestionResult(suggestions: [], usedDictionaryForms: ["辰巳商事"])
        }
        model.corrected = "辰巳商事です。"
        XCTAssertEqual(model.notice, "辞書の『辰巳商事』が使われています。辞書の画面で見直せます")
        let plain = HaasCorrectionPanelModel(draft: draft(.copyOnly(.noRecord))) { _ in
            HaasSuggestionResult(suggestions: [], usedDictionaryForms: [])
        }
        XCTAssertNil(plain.notice)
    }

    func testSessionGateIgnoresSecondOpenAndSerializesClose() {
        var gate = HaasCorrectionSessionGate()
        XCTAssertTrue(gate.tryOpen())
        XCTAssertFalse(gate.tryOpen(), "開いている間は begin を呼ばせない")
        XCTAssertTrue(gate.beginClose())
        XCTAssertFalse(gate.beginClose(), "確定と取り消しは同じ閉じ方で両方走らない")
        XCTAssertFalse(gate.tryOpen(), "確定中は開かせない")
        gate.finish()
        XCTAssertTrue(gate.tryOpen())
    }

    func testCancelAfterCloseDoesNothing() {
        var gate = HaasCorrectionSessionGate()
        XCTAssertFalse(gate.beginClose(), "開いていなければ閉じる処理もない")
    }

    func testInvalidatesInputWatchOnlyForOtherUtilityActions() {
        XCTAssertTrue(RecordingShortcutManager.invalidatesInputWatch(.pasteLastTranscription))
        XCTAssertTrue(RecordingShortcutManager.invalidatesInputWatch(.openQuickHistory))
        XCTAssertFalse(RecordingShortcutManager.invalidatesInputWatch(.correctLastInput))
        XCTAssertFalse(RecordingShortcutManager.invalidatesInputWatch(.primaryRecording))
        XCTAssertFalse(RecordingShortcutManager.invalidatesInputWatch(.secondaryRecording))
    }

    func testCorrectLastInputShortcutAction() {
        XCTAssertEqual(ShortcutAction.correctLastInput.userDefaultsKey, "Shortcut_correctLastInput")
        XCTAssertEqual(ShortcutAction.correctLastInput.displayName, "直前の入力を直す")
        XCTAssertTrue(ShortcutAction.globalUtilityActions.contains(.correctLastInput))
        XCTAssertTrue(ShortcutAction.legacyKeyboardShortcutActions.contains(.correctLastInput))
    }

    func testDefaultExcludedShortcutsIncludeCorrectionShortcut() {
        let key = ShortcutAction.correctLastInput.userDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        addTeardownBlock {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let shortcut = Shortcut.key(keyCode: 6, modifierFlags: [.control, .option])
        ShortcutStore.setShortcut(shortcut, for: .correctLastInput)
        XCTAssertEqual(ShortcutStore.shortcut(for: .correctLastInput), shortcut)
        XCTAssertTrue(HaasUserInputMonitor.defaultExcludedShortcuts().contains(shortcut))
    }
}
