import SwiftData
import XCTest
@testable import VoiceInk

@MainActor
final class HaasInputDeliveryTests: XCTestCase {
    func testBeginStartsInputWatch() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        XCTAssertNil(fixture.delivery.watchToken)
        try await fixture.delivery.begin(sessionID: UUID(), target: nil)
        XCTAssertEqual(fixture.monitor.startCount, 1)
        XCTAssertEqual(fixture.delivery.watchToken, fixture.monitor.lastToken)
    }

    func testLastDeliveredInputPairsRecordWithItsOwnWatchToken() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        XCTAssertNil(fixture.delivery.lastDeliveredInput)
        let first = UUID(), transcriptionID = UUID()
        try await fixture.delivery.begin(sessionID: first, target: AvailableInputTarget())
        fixture.delivery.accept(sessionID: first, itemID: "item-1", text: "前半、")
        fixture.delivery.accept(sessionID: first, itemID: "item-2", text: "後半。")
        // 録音中は直前の入力として扱わない
        XCTAssertNil(fixture.delivery.lastDeliveredInput)
        await fixture.delivery.finish(sessionID: first)
        fixture.delivery.attachTranscription(sessionID: first, transcriptionID: transcriptionID)

        let input = try XCTUnwrap(fixture.delivery.lastDeliveredInput)
        XCTAssertEqual(input.sessionID, first)
        XCTAssertEqual(input.transcriptionID, transcriptionID)
        XCTAssertEqual(input.text, "前半、後半。")
        XCTAssertTrue(input.allSegmentsPosted)
        XCTAssertNotNil(input.target)
        let firstToken = try XCTUnwrap(fixture.monitor.lastToken)
        XCTAssertEqual(input.watchToken, firstToken)

        // 開始に失敗しても、前回の記録と前回の印の組のまま返す
        try fixture.breakStorageDirectory()
        do {
            try await fixture.delivery.begin(sessionID: UUID(), target: AvailableInputTarget())
            XCTFail("保存できない開始は失敗する")
        } catch {}
        let afterFailure = try XCTUnwrap(fixture.delivery.lastDeliveredInput)
        XCTAssertEqual(afterFailure.sessionID, first)
        XCTAssertEqual(afterFailure.watchToken, firstToken)
    }

    func testRecordsFieldOnlyBeforeFirstPaste() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let target = ReadableInputTarget(text: "前の文。")
        fixture.paster.onStarted = { [paster = fixture.paster] in target.text += paster.calls.last?.text ?? "" }
        let session = UUID()
        try await fixture.delivery.begin(sessionID: session, target: target)
        fixture.delivery.accept(sessionID: session, itemID: "item-1", text: "前半、")
        fixture.delivery.accept(sessionID: session, itemID: "item-2", text: "後半。")
        await fixture.delivery.finish(sessionID: session)

        let input = try XCTUnwrap(fixture.delivery.lastDeliveredInput)
        XCTAssertEqual(target.text, "前の文。前半、後半。")
        // 2つ目の区切りの前には読み直さない
        XCTAssertEqual(input.insertionBaseline, .readable(textBeforeInsertion: "前の文。"))
        XCTAssertEqual(target.reads, 1)

        // 次の録音では、その録音の最初の貼り付けの前に読み直す
        let next = UUID()
        try await fixture.delivery.begin(sessionID: next, target: target)
        fixture.delivery.accept(sessionID: next, itemID: "item-1", text: "次。")
        await fixture.delivery.finish(sessionID: next)
        XCTAssertEqual(
            fixture.delivery.lastDeliveredInput?.insertionBaseline,
            .readable(textBeforeInsertion: "前の文。前半、後半。"))
    }

    func testFieldWithSelectionBeforePasteIsRecordedAsUnreadable() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let target = ReadableInputTarget(text: "前の文。")
        target.selectionLength = 2
        let session = UUID()
        try await fixture.delivery.begin(sessionID: session, target: target)
        fixture.delivery.accept(sessionID: session, itemID: "item-1", text: "はい")
        await fixture.delivery.finish(sessionID: session)
        XCTAssertEqual(fixture.delivery.lastDeliveredInput?.insertionBaseline, .unreadable)
    }

    func testIgnoredPasteIntoFieldEndingWithSameTextIsNotReplaced() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        // 文字数の上限で貼り付けが無視される欄。元から「はい」で終わっている
        let target = ReadableInputTarget(text: "はい")
        let session = UUID()
        try await fixture.delivery.begin(sessionID: session, target: target)
        fixture.delivery.accept(sessionID: session, itemID: "item-1", text: "はい")
        await fixture.delivery.finish(sessionID: session)
        XCTAssertEqual(fixture.delivery.lastDeliveredInput?.allSegmentsPosted, true)

        let schema = Schema([Transcription.self, WordReplacement.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let coordinator = HaasCorrectionCoordinator(
            delivery: fixture.delivery, monitor: fixture.monitor, replacer: HaasSystemCorrectionReplacer(),
            settings: HaasSettingsStore(defaults: fixture.defaults), modelContext: container.mainContext,
            isIdle: { true }, captureReturnTarget: { nil }, waitForFocus: { _ in })
        let draft = try XCTUnwrap(coordinator.begin())
        XCTAssertEqual(draft.decision, .copyOnly(.textMismatch))
    }

    func testLastDeliveredInputIsNotAllPostedWhenHeldOrEmpty() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let empty = UUID()
        try await fixture.delivery.begin(sessionID: empty, target: AvailableInputTarget())
        await fixture.delivery.finish(sessionID: empty)
        XCTAssertEqual(fixture.delivery.lastDeliveredInput?.allSegmentsPosted, false)

        let held = UUID()
        try await fixture.delivery.begin(sessionID: held, target: nil)
        fixture.delivery.accept(sessionID: held, itemID: "item-1", text: "保留した文")
        await fixture.delivery.finish(sessionID: held)
        let input = try XCTUnwrap(fixture.delivery.lastDeliveredInput)
        XCTAssertEqual(input.text, "保留した文")
        XCTAssertFalse(input.allSegmentsPosted)
        XCTAssertNil(input.target)
    }

    func testResumeInNewlyCapturedTargetNeverAllowsReplacement() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let session = UUID()
        let first = SwitchableInputTarget(identifier: "test.first")
        try await fixture.delivery.begin(sessionID: session, target: first)
        let token = try XCTUnwrap(fixture.monitor.lastToken)
        fixture.delivery.accept(sessionID: session, itemID: "item-1", text: "前半、")
        await waitUntil { fixture.paster.calls.count == 1 && fixture.delivery.pendingText.isEmpty }

        // 録音の途中で入力先が変わり、残りを保留する
        first.rejection = "focus_changed"
        fixture.delivery.accept(sessionID: session, itemID: "item-2", text: "後半。")
        await waitUntil { fixture.delivery.isPaused && fixture.delivery.pendingText == "後半。" }
        await fixture.delivery.finish(sessionID: session)
        XCTAssertTrue(fixture.monitor.isClean(for: token), "保留しただけでは見張りは崩れない")

        // 「3秒後に選択した欄で再開」で、新しい欄 (中身を読めない) に残りを入れる
        let second = SwitchableInputTarget(identifier: "test.second")
        fixture.capturedTarget.target = second
        fixture.delivery.scheduleResume()
        await waitUntil(timeout: .seconds(5)) {
            fixture.paster.calls.count == 2 && fixture.delivery.pendingText.isEmpty
                && fixture.delivery.lastDeliveredInput != nil
        }
        XCTAssertEqual(fixture.paster.calls.map(\.text), ["前半、", "後半。"])

        let input = try XCTUnwrap(fixture.delivery.lastDeliveredInput)
        XCTAssertEqual(input.text, "前半、後半。")
        XCTAssertEqual(input.target?.diagnosticAppIdentifier, "test.second")
        // 新しい欄には後半しか入っていないので、全文を消させない
        XCTAssertFalse(input.allSegmentsPosted)
        XCTAssertEqual(fixture.monitor.invalidateCount, 1)
        XCTAssertFalse(fixture.monitor.isClean(for: token))

        // 訂正のホットキーで開いても、コピーだけになる
        let schema = Schema([Transcription.self, WordReplacement.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let coordinator = HaasCorrectionCoordinator(
            delivery: fixture.delivery, monitor: fixture.monitor, replacer: HaasSystemCorrectionReplacer(),
            settings: HaasSettingsStore(defaults: fixture.defaults), modelContext: container.mainContext,
            isIdle: { true }, captureReturnTarget: { nil }, waitForFocus: { _ in })
        let draft = try XCTUnwrap(coordinator.begin())
        XCTAssertEqual(draft.originalText, "前半、後半。")
        XCTAssertEqual(draft.decision, .copyOnly(.notAllPosted))
    }

    func testUnresolvedSessionsAreArchivedWithoutBlockingOrMixingNewInput() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let first = UUID(), second = UUID(), current = UUID()
        try await fixture.delivery.begin(sessionID: first, target: nil)
        fixture.delivery.accept(sessionID: first, itemID: "item-1", text: "前の未入力文")
        await fixture.delivery.finish(sessionID: first)
        try await fixture.delivery.begin(sessionID: second, target: nil)
        fixture.delivery.accept(sessionID: second, itemID: "item-1", text: "別の未入力文")
        await fixture.delivery.finish(sessionID: second)
        try await fixture.delivery.begin(sessionID: current, target: nil)

        fixture.delivery.accept(sessionID: first, itemID: "late", text: "混ぜてはいけない文")
        fixture.delivery.cancel(sessionID: first, message: "古い取消")
        fixture.delivery.pause(sessionID: first, message: "古い失敗")
        XCTAssertTrue(fixture.delivery.ledger.fullText.isEmpty)
        XCTAssertEqual(Set(fixture.delivery.archivedRecoveries.map(\.id)), Set([first, second]))

        fixture.delivery.accept(sessionID: current, itemID: "item-1", text: "今回の本文")
        fixture.delivery.copyArchivedRecovery(id: first, kind: .pending)
        XCTAssertEqual(fixture.paster.copiedTexts, ["前の未入力文"])
        XCTAssertEqual(fixture.delivery.archivedRecoveries.count, 2)
        fixture.delivery.acknowledgeArchivedRecovery(id: first)
        XCTAssertEqual(fixture.delivery.archivedRecoveries.map(\.id), [second])
        XCTAssertEqual(fixture.delivery.ledger.fullText, "今回の本文")
        XCTAssertTrue(fixture.paster.calls.isEmpty)
        await fixture.delivery.finish(sessionID: current)
    }

    func testRolloverWaitsForOldPasteResultAndDoesNotCancelNewOwner() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let oldID = UUID(), newID = UUID()
        let started = expectation(description: "Actual output boundary reached")
        fixture.paster.hold = true
        fixture.paster.onStarted = { started.fulfill() }
        try await fixture.delivery.begin(sessionID: oldID, target: AvailableInputTarget())
        fixture.delivery.accept(sessionID: oldID, itemID: "item-1", text: "確認が必要な旧文")
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(try fixture.savedState().active?.ledger.segments.first?.disposition, .posting)

        var didBegin = false
        let next = Task { @MainActor in
            try await fixture.delivery.begin(sessionID: newID, target: AvailableInputTarget())
            didBegin = true
        }
        await waitUntil { fixture.paster.calls.first?.shouldPaste() == false }
        XCTAssertFalse(didBegin)
        XCTAssertTrue(fixture.delivery.archivedRecoveries.isEmpty)
        fixture.delivery.cancel(sessionID: oldID, message: "遅い取消")
        fixture.delivery.pause(sessionID: oldID, message: "遅い失敗")
        fixture.paster.hold = false
        fixture.paster.onStarted = nil
        try fixture.paster.complete(index: 0, result: .commandPartiallyPosted)
        try await next.value

        XCTAssertEqual(fixture.delivery.archivedRecoveries.first?.id, oldID)
        XCTAssertEqual(fixture.delivery.archivedRecoveries.first?.ledger.uncertainText, "確認が必要な旧文")
        fixture.delivery.accept(sessionID: oldID, itemID: "late", text: "旧callback")
        fixture.delivery.cancel(sessionID: oldID, message: "新録音を止めてはいけない")
        fixture.delivery.accept(sessionID: newID, itemID: "item-1", text: "今回だけの文")
        await fixture.delivery.finish(sessionID: newID)
        XCTAssertEqual(fixture.paster.calls.map(\.text), ["確認が必要な旧文", "今回だけの文"])
        XCTAssertEqual(fixture.delivery.ledger.fullText, "今回だけの文")
        XCTAssertEqual(fixture.delivery.ledger.segments.first?.disposition, .posted)

        let reopened = HaasInputDelivery(
            store: HaasRecoveryStore(fileURL: fixture.fileURL, legacyDefaults: fixture.defaults),
            textPaster: ControlledTextPaster(),
            inputMonitor: FakeInputWatcher()
        )
        XCTAssertEqual(reopened.archivedRecoveries.first?.id, oldID)
        XCTAssertEqual(reopened.archivedRecoveries.first?.ledger.uncertainText, "確認が必要な旧文")
    }

    func testCancellationWhileBeginWaitsDoesNotPublishTheCancelledSession() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let oldID = UUID(), cancelledID = UUID(), nextID = UUID()
        let started = expectation(description: "Old paste is in flight")
        fixture.paster.hold = true
        fixture.paster.onStarted = { started.fulfill() }
        try await fixture.delivery.begin(sessionID: oldID, target: AvailableInputTarget())
        fixture.delivery.accept(sessionID: oldID, itemID: "item-1", text: "旧文")
        await fulfillment(of: [started], timeout: 1)
        let cancelledBegin = Task { @MainActor in
            try await fixture.delivery.begin(sessionID: cancelledID, target: nil)
        }
        await waitUntil { fixture.paster.calls.first?.shouldPaste() == false }
        fixture.delivery.cancel(sessionID: cancelledID, message: "準備を取り消した")
        try fixture.paster.complete(index: 0, result: .commandNotPosted)
        do {
            try await cancelledBegin.value
            XCTFail("Cancelled begin must not publish a new active session")
        } catch is CancellationError {}
        XCTAssertEqual(fixture.delivery.pendingText, "旧文")
        XCTAssertTrue(fixture.delivery.archivedRecoveries.isEmpty)

        try await fixture.delivery.begin(sessionID: nextID, target: nil)
        XCTAssertEqual(fixture.delivery.archivedRecoveries.first?.id, oldID)
        XCTAssertTrue(fixture.delivery.ledger.fullText.isEmpty)
        await fixture.delivery.finish(sessionID: nextID)
    }

    func testIncomingTextSurvivesSaveFailureAndNewBeginIsBlocked() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        try await fixture.delivery.begin(sessionID: id, target: nil)
        try fixture.breakStorageDirectory()
        fixture.delivery.accept(sessionID: id, itemID: "item-1", text: "保存できなくても残す本文")
        XCTAssertEqual(fixture.delivery.pendingText, "保存できなくても残す本文")
        XCTAssertTrue(fixture.delivery.hasUnsavedRecovery)
        XCTAssertTrue(fixture.paster.calls.isEmpty)
        do {
            try await fixture.delivery.begin(sessionID: UUID(), target: nil)
            XCTFail("Unsaved text must not be replaced by a new session")
        } catch {}
        fixture.delivery.copyPending()
        XCTAssertEqual(fixture.paster.copiedTexts, ["保存できなくても残す本文"])
        XCTAssertEqual(fixture.delivery.pendingText, "保存できなくても残す本文")
        await fixture.delivery.finish(sessionID: id)
    }

    func testPostingMustBeSavedBeforeAnyPasteCall() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        try await fixture.delivery.begin(sessionID: id, target: AvailableInputTarget())
        fixture.delivery.accept(sessionID: id, itemID: "item-1", text: "まだ送ってはいけない文")
        try fixture.breakStorageDirectory()
        await fixture.delivery.finish(sessionID: id)
        XCTAssertTrue(fixture.paster.calls.isEmpty)
        XCTAssertEqual(fixture.delivery.pendingText, "まだ送ってはいけない文")
        XCTAssertTrue(fixture.delivery.hasUnsavedRecovery)
    }

    func testSessionSavesEachReceiptBeforeGenerationAndDeliversHeldHeadInOrder() async throws {
        let fixture = try DeliveryFixture()
        let generator = ControlledPunctuationGenerator()
        let session = try makeSession(fixture, worker: HaasPunctuationWorker(generator: generator))
        defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
        try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

        session.receive(.committed(id: "first", text: "自販の資料です"))
        XCTAssertEqual(try fixture.savedState().active?.ledger.fullText, "JiHANの資料です")
        XCTAssertEqual(session.recognizedText, "JiHANの資料です")
        session.receive(.committed(id: "second", text: "続けます"))
        XCTAssertEqual(try fixture.savedState().active?.ledger.fullText, "JiHANの資料です続けます")
        XCTAssertTrue(fixture.paster.calls.isEmpty)
        await waitUntil { generator.requests.count == 1 }
        XCTAssertEqual(generator.requests, ["JiHANの資料です"])

        let exited = expectation(description: "Completed punctuation is consumed")
        generator.onExited = { _ in exited.fulfill() }
        try generator.complete(index: 0, result: .success("JiHANの資料です。"))
        await fulfillment(of: [exited], timeout: 1)
        await waitUntil { session.recognizedText == "JiHANの資料です。続けます" }
        await fixture.delivery.finish(sessionID: session.sessionID)
        XCTAssertEqual(fixture.paster.calls.map(\.text), ["JiHANの資料です。", "続けます"])
        XCTAssertEqual(session.recognizedText, "JiHANの資料です。続けます")
        XCTAssertEqual(try fixture.savedState().active?.ledger.fullText, session.recognizedText)

        session.receive(.committed(id: "first", text: "自販の資料です"))
        XCTAssertEqual(generator.requests.count, 1)
        XCTAssertEqual(fixture.paster.calls.count, 2)
    }

    func testCanceledOrFailedFormattingDoesNotDelayOrChangeTheNextSession() async throws {
        for recognitionFailed in [false, true] {
            let fixture = try DeliveryFixture()
            let generator = ControlledPunctuationGenerator()
            let worker = HaasPunctuationWorker(generator: generator)
            let old = try makeSession(fixture, worker: worker)
            let next = try makeSession(fixture, worker: worker)
            defer { old.cancel(); next.cancel(); generator.cancelPending(); fixture.cleanUp() }
            try await fixture.delivery.begin(sessionID: old.sessionID, target: AvailableInputTarget())
            old.receive(.committed(id: "item-1", text: "前の資料です"))
            await waitUntil { generator.requests.count == 1 }
            if recognitionFailed { old.receive(.error(URLError(.networkConnectionLost))) }
            else { old.cancel() }
            XCTAssertEqual(try fixture.savedState().active?.ledger.pendingText, "前の資料です")
            XCTAssertEqual(old.recognizedText, "前の資料です")

            try await fixture.delivery.begin(sessionID: next.sessionID, target: AvailableInputTarget())
            next.receive(.committed(id: "item-1", text: "今回の資料です"))
            await fixture.delivery.finish(sessionID: next.sessionID)
            XCTAssertEqual(generator.requests.count, 1, "The canceled native request still owns the generation slot")
            XCTAssertEqual(fixture.paster.calls.map(\.text), ["今回の資料です"])
            XCTAssertEqual(next.recognizedText, "今回の資料です")
            XCTAssertEqual(fixture.delivery.archivedRecoveries.first?.ledger.pendingText, "前の資料です")

            let exited = expectation(description: "Old native result arrives after the next recording")
            generator.onExited = { _ in exited.fulfill() }
            try generator.complete(index: 0, result: .success("前の資料です。"))
            await fulfillment(of: [exited], timeout: 1)
            XCTAssertEqual(old.recognizedText, "前の資料です")
            XCTAssertEqual(next.recognizedText, "今回の資料です")
            XCTAssertEqual(try fixture.savedState().active?.ledger.fullText, "今回の資料です")
            XCTAssertEqual(fixture.delivery.archivedRecoveries.first?.ledger.fullText, "前の資料です")
            XCTAssertEqual(fixture.paster.calls.count, 1)
        }
    }

    func testCopyWinsOverLateFormattingAndKeepsSessionHistoryIdentical() async throws {
        let fixture = try DeliveryFixture()
        let generator = ControlledPunctuationGenerator()
        let session = try makeSession(fixture, worker: HaasPunctuationWorker(generator: generator))
        defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
        try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())
        session.receive(.committed(id: "item-1", text: "コピーする資料です"))
        await waitUntil { generator.requests.count == 1 }
        fixture.delivery.copyPending()
        XCTAssertEqual(fixture.paster.copiedTexts, ["コピーする資料です"])
        XCTAssertEqual(try fixture.savedState().active?.ledger.segments.first?.disposition, .copied)

        let exited = expectation(description: "AI finishes after manual copy")
        generator.onExited = { _ in exited.fulfill() }
        try generator.complete(index: 0, result: .success("コピーする資料です。"))
        await fulfillment(of: [exited], timeout: 1)
        XCTAssertEqual(session.recognizedText, "コピーする資料です")
        XCTAssertEqual(try fixture.savedState().active?.ledger.fullText, session.recognizedText)
        XCTAssertTrue(fixture.paster.calls.isEmpty)
    }

    func testFormattingSaveFailurePreservesTheDurableBaseAndStopsInput() async throws {
        let fixture = try DeliveryFixture()
        let generator = ControlledPunctuationGenerator()
        let session = try makeSession(fixture, worker: HaasPunctuationWorker(generator: generator))
        defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
        try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())
        session.receive(.committed(id: "item-1", text: "保存してから整えます"))
        await waitUntil { generator.requests.count == 1 }
        try fixture.breakStorageDirectory()

        let exited = expectation(description: "Formatting save fails")
        generator.onExited = { _ in exited.fulfill() }
        try generator.complete(index: 0, result: .success("保存してから整えます。"))
        await fulfillment(of: [exited], timeout: 1)
        await waitUntil { fixture.delivery.hasUnsavedRecovery }
        XCTAssertTrue(fixture.delivery.hasUnsavedRecovery)
        XCTAssertEqual(session.recognizedText, "保存してから整えます")
        XCTAssertEqual(fixture.delivery.pendingText, session.recognizedText)
        XCTAssertTrue(fixture.paster.calls.isEmpty)
        fixture.delivery.copyPending()
        XCTAssertEqual(fixture.paster.copiedTexts, ["保存してから整えます"])
        let retained = try JSONDecoder().decode(HaasRecoveryState.self, from: Data(contentsOf:
            fixture.root.appendingPathComponent("retained-storage/state.json")))
        XCTAssertEqual(retained.active?.ledger.pendingText, session.recognizedText)
    }

    func testFormattingCannotRewritePostingUncertainOrAcknowledgedInput() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let sessionID = UUID(), requestID = UUID()
        let started = expectation(description: "Finalized text reaches paste boundary")
        fixture.paster.hold = true
        fixture.paster.onStarted = { started.fulfill() }
        try await fixture.delivery.begin(sessionID: sessionID, target: AvailableInputTarget())
        XCTAssertTrue(fixture.delivery.accept(
            sessionID: sessionID, itemID: "item-1", text: "確認します", formattingHoldID: requestID
        ))
        XCTAssertTrue(fixture.delivery.completeHeldFormatting(
            sessionID: sessionID, itemID: "item-1", requestID: requestID, text: "確認します。"
        ))
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(fixture.delivery.completeHeldFormatting(
            sessionID: sessionID, itemID: "item-1", requestID: requestID, text: "後から変更"
        ))
        try fixture.paster.complete(index: 0, result: .commandPartiallyPosted)
        await waitUntil { fixture.delivery.uncertainText == "確認します。" }
        XCTAssertEqual(fixture.delivery.uncertainText, "確認します。")
        XCTAssertFalse(fixture.delivery.completeHeldFormatting(
            sessionID: sessionID, itemID: "item-1", requestID: requestID, text: "後から変更"
        ))
        fixture.delivery.acknowledgeUncertainInput()
        XCTAssertEqual(fixture.delivery.ledger.segments.first?.disposition, .copied)
        XCTAssertFalse(fixture.delivery.completeHeldFormatting(
            sessionID: sessionID, itemID: "item-1", requestID: requestID, text: "後から変更"
        ))
        XCTAssertEqual(try fixture.savedState().active?.ledger.fullText, "確認します。")
        await fixture.delivery.finish(sessionID: sessionID)
    }

    func testProofreadDeliversCorrectedTextFromGenerator() async throws {
        let fixture = try DeliveryFixture()
        let generator = ControlledPunctuationGenerator()
        let session = try makeProofreadSession(fixture, worker: proofreadWorker(generator, timeout: .seconds(2)))
        defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
        try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

        session.receive(.committed(id: "first", text: "辰美さんの端末ないで"))
        await waitUntil { generator.requests.count == 1 }
        XCTAssertEqual(generator.requests, ["巽さんの端末ないで"])
        try generator.complete(index: 0, result: .success("巽さんの端末内で"))
        await waitUntil { session.recognizedText == "巽さんの端末内で" }
        await fixture.delivery.finish(sessionID: session.sessionID)
        XCTAssertEqual(fixture.paster.calls.map(\.text), ["巽さんの端末内で"])
    }

    func testProofreadFallsBackToMatchedOriginalWhenGeneratorDoesNotReturnInTime() async throws {
        let fixture = try DeliveryFixture()
        let generator = ControlledPunctuationGenerator()
        let session = try makeProofreadSession(fixture, worker: proofreadWorker(generator, timeout: .milliseconds(100)))
        defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
        try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

        session.receive(.committed(id: "first", text: "辰美さんの端末ないで"))
        await waitUntil { session.recognizedText == "巽さんの端末ないで" && fixture.paster.calls.count == 1 }
        await fixture.delivery.finish(sessionID: session.sessionID)
        XCTAssertEqual(fixture.paster.calls.map(\.text), ["巽さんの端末ないで"])
    }

    func testProofreadProtectsReplacementRuleOutputs() async throws {
        let fixture = try DeliveryFixture()
        let generator = ControlledPunctuationGenerator()
        let session = try HaasDictationSession(
            runtime: .bundled(directory: fixture.root), words: "", inputTarget: nil, onPartialTranscript: nil,
            replacementPlan: WordReplacementPlan(records: [
                .init(id: UUID(), originalText: "ジハン", replacementText: "自販", dateAdded: Date()),
            ]),
            punctuationMode: .proofread, punctuationWorker: proofreadWorker(generator, timeout: .seconds(2)),
            delivery: fixture.delivery
        )
        defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
        try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

        session.receive(.committed(id: "first", text: "ジハンの件です"))
        await waitUntil { generator.requests.count == 1 }
        XCTAssertEqual(generator.requests, ["自販の件です"])
        try generator.complete(index: 0, result: .success("次半の件です"))
        await waitUntil { session.recognizedText == "自販の件です" && fixture.paster.calls.count == 1 }
        await fixture.delivery.finish(sessionID: session.sessionID)
        XCTAssertEqual(fixture.paster.calls.map(\.text), ["自販の件です"])
    }

    func testProofreadDeliversOriginalWhenCandidateReducesToNothing() async throws {
        let fixture = try DeliveryFixture()
        let generator = ControlledPunctuationGenerator()
        let session = try makeProofreadSession(fixture, worker: proofreadWorker(generator, timeout: .seconds(2)))
        defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
        try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

        session.receive(.committed(id: "first", text: "して"))
        await waitUntil { generator.requests.count == 1 }
        try generator.complete(index: 0, result: .success("。"))
        await waitUntil { session.recognizedText == "して" && fixture.paster.calls.count == 1 }
        session.receive(.committed(id: "second", text: "確認します"))
        await waitUntil { generator.requests.count == 2 }
        try generator.complete(index: 1, result: .success("確認します。"))
        await waitUntil { fixture.paster.calls.count == 2 }
        await fixture.delivery.finish(sessionID: session.sessionID)
        XCTAssertEqual(fixture.paster.calls.map(\.text).first, "して")
        XCTAssertEqual(fixture.paster.calls.count, 2)
    }

    private func proofreadWorker(_ generator: ControlledPunctuationGenerator, timeout: Duration) -> HaasPunctuationWorker {
        HaasPunctuationWorker(generator: generator, timeout: timeout) { candidate, original, terms in
            HaasProofreadValidator.validatedCandidate(candidate, preserving: original, protectedTerms: terms)
        }
    }

    private func makeProofreadSession(_ fixture: DeliveryFixture, worker: HaasPunctuationWorker) throws -> HaasDictationSession {
        try HaasDictationSession(
            runtime: .bundled(directory: fixture.root), words: "", inputTarget: nil, onPartialTranscript: nil,
            replacementPlan: WordReplacementPlan(records: []),
            vocabularyEntries: [HaasVocabularyEntry(id: UUID(), writtenForm: "巽", readings: ["たつみ"], category: .person)],
            punctuationMode: .proofread, punctuationWorker: worker, delivery: fixture.delivery
        )
    }

    private func makeSession(_ fixture: DeliveryFixture, worker: HaasPunctuationWorker) throws -> HaasDictationSession {
        let replacements = try WordReplacementPlan(records: [
            .init(id: UUID(), originalText: "自販", replacementText: "JiHAN", dateAdded: Date()),
            .init(id: UUID(), originalText: "JiHAN", replacementText: "二度目の置換", dateAdded: Date()),
        ])
        return HaasDictationSession(
            runtime: .bundled(directory: fixture.root), words: "", inputTarget: nil, onPartialTranscript: nil,
            replacementPlan: replacements, punctuationMode: .natural, punctuationWorker: worker, delivery: fixture.delivery
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1), _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class DeliveryFixture {
    let root: URL
    let fileURL: URL
    let defaults: UserDefaults
    let suite: String
    let paster = ControlledTextPaster()
    let monitor = FakeInputWatcher()
    /// 再開のときに取る入力先
    let capturedTarget = CapturedTargetBox()
    let delivery: HaasInputDelivery

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("haas-delivery-\(UUID().uuidString)")
        fileURL = root.appendingPathComponent("storage/state.json")
        suite = "HaasDeliveryTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        delivery = HaasInputDelivery(
            store: HaasRecoveryStore(fileURL: fileURL, legacyDefaults: defaults), textPaster: paster,
            inputMonitor: monitor, captureTarget: { [capturedTarget] in capturedTarget.target }
        )
    }

    func savedState() throws -> HaasRecoveryState {
        try JSONDecoder().decode(HaasRecoveryState.self, from: Data(contentsOf: fileURL))
    }

    func breakStorageDirectory() throws {
        let storage = fileURL.deletingLastPathComponent()
        try FileManager.default.moveItem(at: storage, to: root.appendingPathComponent("retained-storage"))
        try Data("not a directory".utf8).write(to: storage)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private struct AvailableInputTarget: HaasInputTargetChecking {
    let diagnosticAppIdentifier = "test.destination"
    func rejectionReason() -> String? { nil }
}

/// カーソルが末尾にある、中身を読める入力先
@MainActor
private final class ReadableInputTarget: HaasInputTargetChecking {
    let diagnosticAppIdentifier = "test.readable"
    var text: String
    var selectionLength = 0
    private(set) var reads = 0
    init(text: String) { self.text = text }
    func rejectionReason() -> String? { nil }
    func fieldState() -> HaasFieldState {
        reads += 1
        return .readable(textBeforeCaret: text, textAfterCaret: "", selectionLength: selectionLength)
    }
}

@MainActor
private final class SwitchableInputTarget: HaasInputTargetChecking {
    let diagnosticAppIdentifier: String
    var rejection: String?
    init(identifier: String) { diagnosticAppIdentifier = identifier }
    func rejectionReason() -> String? { rejection }
}

@MainActor
private final class CapturedTargetBox {
    var target: (any HaasInputTargetChecking)?
}

@MainActor
private final class ControlledTextPaster: HaasTextPasting {
    struct Call {
        let text: String
        let shouldPaste: () -> Bool
    }
    var hold = false
    var onStarted: (() -> Void)?
    private(set) var calls: [Call] = []
    private(set) var copiedTexts: [String] = []
    private var continuations: [Int: CheckedContinuation<CursorPaster.PasteOutcome, Never>] = [:]

    func paste(_ text: String, shouldPaste: @escaping () -> Bool) async -> CursorPaster.PasteOutcome {
        let index = calls.count
        calls.append(Call(text: text, shouldPaste: shouldPaste))
        onStarted?()
        if hold {
            return await withCheckedContinuation { continuations[index] = $0 }
        }
        return CursorPaster.PasteOutcome(result: .commandPosted)
    }

    func copy(_ text: String) -> Bool {
        copiedTexts.append(text)
        return true
    }

    func complete(index: Int, result: CursorPaster.PasteResult) throws {
        let continuation = try XCTUnwrap(continuations.removeValue(forKey: index))
        continuation.resume(returning: CursorPaster.PasteOutcome(result: result))
    }
}

@MainActor
private final class FakeInputWatcher: HaasInputWatching {
    private(set) var startCount = 0
    private(set) var invalidateCount = 0
    private(set) var lastToken: UUID?
    func startWatching() -> UUID {
        startCount += 1
        let token = UUID()
        lastToken = token
        return token
    }
    func isClean(for token: UUID) -> Bool { token == lastToken }
    func invalidate() {
        invalidateCount += 1
        lastToken = nil
    }
}
