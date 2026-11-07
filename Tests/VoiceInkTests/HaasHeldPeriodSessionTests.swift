import XCTest
@testable import VoiceInk

/// 区切りの末尾の「。」を、次の区切りが来てから決める動き。記録 (recognizedText) と配送の台帳が一致することも見る
@MainActor
final class HaasHeldPeriodSessionTests: XCTestCase {
    func testFastModeHoldsEachPeriodAndAddsTheLastOneAtFinish() async throws {
        let fixture = try DeliveryFixture()
        let session = try makeSession(fixture, mode: .fast, worker: HaasPunctuationWorker(generator: nil))
        defer { session.cancel(); fixture.cleanUp() }
        try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

        let segments = [
            ("a", "確認したいです", "確認したいです"),
            ("b", "けど次も見ます", "けど次も見ます"),
            ("c", "そうです", "。そうです"),
            ("d", "ね", "ね"),
            ("e", "次に進みます", "次に進みます"),
        ]
        for (index, segment) in segments.enumerated() {
            session.receive(.committed(id: segment.0, text: segment.1))
            await waitUntil { fixture.paster.calls.count == index + 1 }
            XCTAssertEqual(fixture.paster.calls.last?.text, segment.2, segment.1)
        }
        XCTAssertEqual(session.recognizedText, "確認したいですけど次も見ます。そうですね次に進みます")

        let text = try await session.finishAfterRecognition()
        XCTAssertEqual(text, "確認したいですけど次も見ます。そうですね次に進みます。")
        XCTAssertEqual(fixture.paster.calls.map(\.text), segments.map { $0.2 } + ["。"])
        XCTAssertEqual(fixture.delivery.ledger.segments.last?.id, "e-period")
        XCTAssertEqual(fixture.delivery.ledger.fullText, text)
        XCTAssertEqual(try fixture.savedState().active?.ledger.fullText, text)
        XCTAssertEqual(fixture.delivery.lastDeliveredInput?.text, text)
        XCTAssertEqual(fixture.delivery.lastDeliveredInput?.allSegmentsPosted, true, "最後の「。」も直前の入力の置き換えに使える")
        XCTAssertEqual(session.recognizedText, text)
    }

    func testFormattedPeriodIsHeldUntilTheNextSegmentDecides() async throws {
        let cases: [(next: String, formatted: String, calls: [String])] = [
            ("それで次です", "それで次です。", ["資料です", "。それで次です", "。"]),
            ("けど次です", "けど次です。", ["資料です", "けど次です", "。"]),
            // 誤字も修正モードでは、整形の結果が「。」で始まることもある。二重にしない
            ("それで次です", "。それで次です。", ["資料です", "。それで次です", "。"]),
        ]
        for mode in [HaasPunctuationMode.natural, .proofread] {
            for item in cases where mode == .proofread || !item.formatted.hasPrefix("。") {
                let label = "\(mode) \(item.formatted)"
                let fixture = try DeliveryFixture()
                let generator = ControlledPunctuationGenerator()
                let session = try makeSession(fixture, mode: mode, worker: worker(for: mode, generator))
                defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
                try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

                session.receive(.committed(id: "a", text: "資料です"))
                await waitUntil { generator.requests.count == 1 }
                try generator.complete(index: 0, result: .success("資料です。"))
                await waitUntil { fixture.paster.calls.count == 1 }
                XCTAssertEqual(session.recognizedText, "資料です", label)

                session.receive(.committed(id: "b", text: item.next))
                await waitUntil { generator.requests.count == 2 }
                XCTAssertEqual(generator.requests.last, item.next, "AI には「。」を付けない原文を渡す: \(label)")
                try generator.complete(index: 1, result: .success(item.formatted))
                await waitUntil { fixture.paster.calls.count == 2 }

                let text = try await session.finishAfterRecognition()
                XCTAssertEqual(fixture.paster.calls.map(\.text), item.calls, label)
                XCTAssertEqual(text, item.calls.joined(), label)
                XCTAssertEqual(fixture.delivery.ledger.fullText, text, label)
                XCTAssertEqual(fixture.delivery.lastDeliveredInput?.text, text, label)
            }
        }
    }

    func testSegmentArrivingDuringFormattingDecidesThatSegmentsPeriod() async throws {
        let cases: [(next: String, calls: [String])] = [
            ("次も見ます", ["資料です。", "次も見ます", "。"]),
            ("けど続けます。", ["資料です", "けど続けます", "。"]),
        ]
        for mode in [HaasPunctuationMode.natural, .proofread] {
            for item in cases {
                let label = "\(mode) \(item.next)"
                let fixture = try DeliveryFixture()
                let generator = ControlledPunctuationGenerator()
                let session = try makeSession(fixture, mode: mode, worker: worker(for: mode, generator))
                defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
                try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

                session.receive(.committed(id: "a", text: "資料です"))
                await waitUntil { generator.requests.count == 1 }
                session.receive(.committed(id: "b", text: item.next))
                XCTAssertTrue(fixture.paster.calls.isEmpty, label)
                XCTAssertEqual(generator.requests.count, 1, label)

                try generator.complete(index: 0, result: .success("資料です。"))
                await waitUntil { fixture.paster.calls.count == 2 }
                let text = try await session.finishAfterRecognition()
                XCTAssertEqual(fixture.paster.calls.map(\.text), item.calls, label)
                XCTAssertEqual(text, item.calls.joined(), label)
                XCTAssertEqual(fixture.delivery.ledger.fullText, text, label)
            }
        }
    }

    func testHeldPeriodReachesLedgerAndRecordOnceWhenDeliveryStopped() async throws {
        for mode in [HaasPunctuationMode.natural, .proofread] {
            let fixture = try DeliveryFixture()
            let generator = ControlledPunctuationGenerator()
            let session = try makeSession(fixture, mode: mode, worker: worker(for: mode, generator))
            defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
            try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

            session.receive(.committed(id: "a", text: "資料です"))
            await waitUntil { generator.requests.count == 1 }
            session.receive(.committed(id: "b", text: "続けます。"))
            fixture.delivery.pauseForPanelDismissal()
            try generator.complete(index: 0, result: .success("資料です。"))

            let text = try await session.finishAfterRecognition()
            // 止めた後の整形は台帳に入らないので、a は受け渡した文 (速度優先の規則を当てたもの) のまま。
            // b の「。」だけ末尾に1つ入る
            XCTAssertEqual(text, "資料です。続けます。", "\(mode)")
            XCTAssertEqual(fixture.delivery.ledger.fullText, text, "\(mode)")
            XCTAssertEqual(fixture.delivery.pendingText, text, "\(mode)")
            XCTAssertEqual(try fixture.savedState().active?.ledger.fullText, text, "\(mode)")
            XCTAssertTrue(fixture.paster.calls.isEmpty, "\(mode)")
        }
    }

    func testCancelDiscardsHeldPeriodAndKeepsRecordEqualToLedger() async throws {
        let fixture = try DeliveryFixture()
        let generator = ControlledPunctuationGenerator()
        let session = try makeSession(fixture, mode: .natural, worker: worker(for: .natural, generator))
        defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
        try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

        session.receive(.committed(id: "a", text: "資料です"))
        await waitUntil { generator.requests.count == 1 }
        try generator.complete(index: 0, result: .success("資料です。"))
        await waitUntil { fixture.paster.calls.count == 1 }
        session.receive(.committed(id: "b", text: "それで次です"))
        await waitUntil { generator.requests.count == 2 }
        session.cancel()

        XCTAssertEqual(session.recognizedText, "資料です。それで次です。")
        XCTAssertEqual(fixture.delivery.ledger.fullText, session.recognizedText)
        do {
            _ = try await session.finishAfterRecognition()
            XCTFail("取り消した録音は終えられない")
        } catch {}
        XCTAssertEqual(fixture.delivery.ledger.fullText, "資料です。それで次です。")
        XCTAssertEqual(fixture.paster.calls.map(\.text), ["資料です"])
        XCTAssertEqual(session.punctuationRoutes["b"], .cancelled)
    }

    func testCancelInFastModeDropsTheHeldPeriod() async throws {
        let fixture = try DeliveryFixture()
        let session = try makeSession(fixture, mode: .fast, worker: HaasPunctuationWorker(generator: nil))
        defer { session.cancel(); fixture.cleanUp() }
        try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

        session.receive(.committed(id: "a", text: "確認します"))
        await waitUntil { fixture.paster.calls.count == 1 }
        session.cancel()
        _ = try? await session.finishAfterRecognition()
        XCTAssertEqual(session.recognizedText, "確認します")
        XCTAssertEqual(fixture.delivery.ledger.fullText, "確認します")
        XCTAssertEqual(fixture.paster.calls.map(\.text), ["確認します"])
    }

    func testRecordMatchesLedgerWhenAcceptCannotSave() async throws {
        let fixture = try DeliveryFixture()
        let generator = ControlledPunctuationGenerator()
        let session = try makeSession(fixture, mode: .natural, worker: worker(for: .natural, generator))
        defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
        try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

        session.receive(.committed(id: "a", text: "資料です"))
        await waitUntil { generator.requests.count == 1 }
        try generator.complete(index: 0, result: .success("資料です。"))
        await waitUntil { fixture.paster.calls.count == 1 }
        try fixture.breakStorageDirectory()
        session.receive(.committed(id: "b", text: "それで次です"))

        XCTAssertTrue(fixture.delivery.hasUnsavedRecovery)
        XCTAssertEqual(generator.requests.count, 1)
        XCTAssertEqual(session.punctuationRoutes["b"], .notAccepted)
        XCTAssertEqual(session.recognizedText, "資料です。それで次です。")
        XCTAssertEqual(fixture.delivery.ledger.fullText, session.recognizedText)
        let text = try await session.finishAfterRecognition()
        XCTAssertEqual(text, "資料です。それで次です。")
        XCTAssertEqual(fixture.delivery.ledger.fullText, text)
    }

    func testRecordMatchesLedgerWhenFormattingResultIsRejected() async throws {
        let fixture = try DeliveryFixture()
        let generator = ControlledPunctuationGenerator()
        let session = try makeSession(fixture, mode: .natural, worker: worker(for: .natural, generator))
        defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
        try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

        // 認識結果がすでに「。」で終わる区切り。整形の結果がなくても、受け渡した文で保留を決める
        session.receive(.committed(id: "a", text: "資料です。"))
        await waitUntil { generator.requests.count == 1 }
        try generator.complete(index: 0, result: .success("全く違う文です。"))
        await waitUntil { fixture.paster.calls.count == 1 }
        XCTAssertEqual(fixture.paster.calls.map(\.text), ["資料です"])

        session.receive(.committed(id: "b", text: "それで"))
        await waitUntil { generator.requests.count == 2 }
        try generator.complete(index: 1, result: .success("違います"))
        await waitUntil { fixture.paster.calls.count == 2 }

        let text = try await session.finishAfterRecognition()
        XCTAssertEqual(fixture.paster.calls.map(\.text), ["資料です", "。それで"])
        XCTAssertEqual(text, "資料です。それで")
        XCTAssertEqual(fixture.delivery.ledger.fullText, text)
    }

    func testRecordMatchesLedgerWhenCompletionCannotSave() async throws {
        let fixture = try DeliveryFixture()
        let generator = ControlledPunctuationGenerator()
        let session = try makeSession(fixture, mode: .natural, worker: worker(for: .natural, generator))
        defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
        try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

        session.receive(.committed(id: "a", text: "資料です"))
        await waitUntil { generator.requests.count == 1 }
        try generator.complete(index: 0, result: .success("資料です。"))
        await waitUntil { fixture.paster.calls.count == 1 }
        session.receive(.committed(id: "b", text: "それで次です"))
        await waitUntil { generator.requests.count == 2 }
        try fixture.breakStorageDirectory()
        // 整形の結果は accept 時の文 (「。それで次です。」) と違うので、整形の完了で保存を試みて失敗する
        try generator.complete(index: 1, result: .success("それで、次です。"))
        await waitUntil { fixture.delivery.hasUnsavedRecovery }

        // completeHeldFormatting が false なので、整形の結果も b の「。」の保留も採らない
        XCTAssertEqual(fixture.delivery.ledger.segments.last?.text, "。それで次です。")
        XCTAssertEqual(session.recognizedText, "資料です。それで次です。")
        XCTAssertEqual(fixture.delivery.ledger.fullText, session.recognizedText)
        let text = try await session.finishAfterRecognition()
        XCTAssertEqual(text, "資料です。それで次です。", "終わりにもう1つ「。」を足さない")
        XCTAssertEqual(fixture.delivery.ledger.fullText, text)
        XCTAssertEqual(session.punctuationRoutes["b"], .notApplied, "検証を通っても台帳に入らなければ、使えたとは残さない")
        XCTAssertEqual(fixture.paster.calls.map(\.text), ["資料です"])
    }

    /// AI の結果を使えない区切りにも、速度優先の規則で「。」「？」を補う。「。」は #12 の規則で保留する
    func testUnusableFormattingFallsBackToFastRules() async throws {
        let routes: [HaasPunctuationRoute] = [.timedOut, .rejected, .failed, .unavailable]
        let cases: [(text: String, calls: [String])] = [
            ("資料です", ["資料です", "。"]),
            ("確認できますか", ["確認できますか？"]),
        ]
        for mode in [HaasPunctuationMode.natural, .proofread] {
            for route in routes {
                for item in cases {
                    let label = "\(mode) \(route) \(item.text)"
                    let fixture = try DeliveryFixture()
                    let generator = ControlledPunctuationGenerator()
                    if route == .unavailable { generator.unavailableReason = "使えません" }
                    let timeout: Duration = route == .timedOut ? .milliseconds(100) : .seconds(2)
                    let session = try makeSession(fixture, mode: mode, worker: worker(for: mode, generator, timeout: timeout))
                    defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
                    try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

                    session.receive(.committed(id: "a", text: item.text))
                    switch route {
                    case .rejected:
                        await waitUntil { generator.requests.count == 1 }
                        try generator.complete(index: 0, result: .success("XYZ" + item.text))
                    case .failed:
                        await waitUntil { generator.requests.count == 1 }
                        try generator.complete(index: 0, result: .failure(FallbackTestError.failed))
                    default:
                        break
                    }
                    await waitUntil { fixture.paster.calls.count == 1 }
                    XCTAssertEqual(session.punctuationRoutes["a"], route, label)

                    let text = try await session.finishAfterRecognition()
                    XCTAssertEqual(fixture.paster.calls.map(\.text), item.calls, label)
                    XCTAssertEqual(text, item.calls.joined(), label)
                    XCTAssertEqual(fixture.delivery.ledger.fullText, text, label)
                }
            }
        }
    }

    func testSegmentArrivingDuringFormattingGetsFastRules() async throws {
        let cases: [(next: String, calls: [String])] = [
            ("確認できますか", ["資料です。", "確認できますか？"]),
            ("次も見ます", ["資料です。", "次も見ます", "。"]),
        ]
        for mode in [HaasPunctuationMode.natural, .proofread] {
            for item in cases {
                let label = "\(mode) \(item.next)"
                let fixture = try DeliveryFixture()
                let generator = ControlledPunctuationGenerator()
                let session = try makeSession(fixture, mode: mode, worker: worker(for: mode, generator))
                defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
                try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

                session.receive(.committed(id: "a", text: "資料です"))
                await waitUntil { generator.requests.count == 1 }
                session.receive(.committed(id: "b", text: item.next))
                XCTAssertEqual(session.punctuationRoutes["b"], .skippedWhileFormatting, label)
                try generator.complete(index: 0, result: .success("資料です。"))
                await waitUntil { fixture.paster.calls.count == 2 }
                XCTAssertEqual(session.punctuationRoutes["a"], .formatted, label)

                let text = try await session.finishAfterRecognition()
                XCTAssertEqual(generator.requests.count, 1, label)
                XCTAssertEqual(fixture.paster.calls.map(\.text), item.calls, label)
                XCTAssertEqual(text, item.calls.joined(), label)
                XCTAssertEqual(fixture.delivery.ledger.fullText, text, label)
            }
        }
    }

    /// 前の区切りが「。」を保留しているところに、AI の結果を使えない区切りが来る
    func testFallbackSegmentResolvesThePreviousHeldPeriod() async throws {
        let cases: [(next: String, calls: [String])] = [
            ("そうです", ["資料です", "。そうです", "。"]),
            ("けど次です", ["資料です", "けど次です", "。"]),
            ("確認できますか", ["資料です", "。確認できますか？"]),
        ]
        for mode in [HaasPunctuationMode.natural, .proofread] {
            for item in cases {
                let label = "\(mode) \(item.next)"
                let fixture = try DeliveryFixture()
                let generator = ControlledPunctuationGenerator()
                let session = try makeSession(fixture, mode: mode, worker: worker(for: mode, generator))
                defer { session.cancel(); generator.cancelPending(); fixture.cleanUp() }
                try await fixture.delivery.begin(sessionID: session.sessionID, target: AvailableInputTarget())

                session.receive(.committed(id: "a", text: "資料です"))
                await waitUntil { generator.requests.count == 1 }
                try generator.complete(index: 0, result: .success("資料です。"))
                await waitUntil { fixture.paster.calls.count == 1 }

                session.receive(.committed(id: "b", text: item.next))
                await waitUntil { generator.requests.count == 2 }
                XCTAssertEqual(generator.requests.last, item.next, label)
                try generator.complete(index: 1, result: .success("XYZ" + item.next))
                await waitUntil { fixture.paster.calls.count == 2 }
                XCTAssertEqual(session.punctuationRoutes, ["a": .formatted, "b": .rejected], label)

                let text = try await session.finishAfterRecognition()
                XCTAssertEqual(fixture.paster.calls.map(\.text), item.calls, label)
                XCTAssertEqual(text, item.calls.joined(), label)
                XCTAssertEqual(fixture.delivery.ledger.fullText, text, label)
                XCTAssertEqual(fixture.delivery.lastDeliveredInput?.text, text, label)
            }
        }
    }

    private func worker(
        for mode: HaasPunctuationMode, _ generator: ControlledPunctuationGenerator, timeout: Duration = .seconds(2)
    ) -> HaasPunctuationWorker {
        guard mode == .proofread else { return HaasPunctuationWorker(generator: generator, timeout: timeout) }
        return HaasPunctuationWorker(generator: generator, timeout: timeout) { candidate, original, terms in
            HaasProofreadValidator.validatedCandidate(candidate, preserving: original, protectedTerms: terms)
        }
    }

    private func makeSession(
        _ fixture: DeliveryFixture, mode: HaasPunctuationMode, worker: HaasPunctuationWorker
    ) throws -> HaasDictationSession {
        HaasDictationSession(
            runtime: .bundled(directory: fixture.root), words: "", inputTarget: nil, onPartialTranscript: nil,
            replacementPlan: try WordReplacementPlan(records: []),
            punctuationMode: mode, punctuationWorker: worker, delivery: fixture.delivery
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

private enum FallbackTestError: Error { case failed }
