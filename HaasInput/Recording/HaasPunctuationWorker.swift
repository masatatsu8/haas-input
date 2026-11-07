import Foundation

@MainActor
protocol HaasPunctuationGenerating: AnyObject {
    var unavailableReason: String? { get }
    func prewarm()
    func generate(_ text: String) async throws -> String
}

/// 区切りの句読点を決めた経路。端末のログに残し、テストでも値で確かめる
enum HaasPunctuationRoute: String {
    /// AI の結果を使えた
    case formatted
    /// AI の結果を検証で外した
    case rejected
    case timedOut
    /// AI がエラーを返した
    case failed
    /// AI が使えないか、前の依頼がまだ終わっていないので、依頼を受けなかった
    case unavailable
    /// 前の区切りの整形中に届いたので、AI に回さなかった
    case skippedWhileFormatting
    /// 受け渡しを保存できなかったので、AI に回さなかった
    case notAccepted
    /// 整形を待つ間に、取り消しか失敗で打ち切った
    case cancelled
}

/// AI に依頼した区切りの結果
enum HaasPunctuationOutcome: Equatable {
    case formatted(String)
    case rejected
    case timedOut
    case failed

    var candidate: String? {
        if case .formatted(let text) = self { return text }
        return nil
    }

    var route: HaasPunctuationRoute {
        switch self {
        case .formatted: .formatted
        case .rejected: .rejected
        case .timedOut: .timedOut
        case .failed: .failed
        }
    }
}

typealias HaasCandidateValidator = @MainActor (_ candidate: String, _ original: String, _ protectedTerms: [String]) -> String?

@MainActor
final class HaasPunctuationWorker {
    static let shared: HaasPunctuationWorker = {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return HaasPunctuationWorker(generator: HaasApplePunctuationGenerator())
        }
        #endif
        return HaasPunctuationWorker(generator: nil)
    }()

    static let proofreading: HaasPunctuationWorker = {
        let validator: HaasCandidateValidator = { candidate, original, terms in
            HaasProofreadValidator.validatedCandidate(candidate, preserving: original, protectedTerms: terms)
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return HaasPunctuationWorker(
                generator: HaasApplePunctuationGenerator(instructions: .proofread),
                timeout: .seconds(2.5), validator: validator)
        }
        #endif
        return HaasPunctuationWorker(generator: nil, timeout: .seconds(2.5), validator: validator)
    }()

    static func forMode(_ mode: HaasPunctuationMode) -> HaasPunctuationWorker {
        mode == .proofread ? proofreading : shared
    }

    private struct Waiter {
        let id: UUID
        let text: String
        let protectedTerms: [String]
        let deadline: ContinuousClock.Instant
        let timer: Task<Void, Never>
        let completion: (HaasPunctuationOutcome) -> Void
    }

    private let generator: (any HaasPunctuationGenerating)?
    private let timeout: Duration
    private let validator: HaasCandidateValidator
    private var nativeRequestID: UUID?
    private var nativeTask: Task<Void, Never>?
    private var waiter: Waiter?

    var unavailableReason: String? {
        guard let generator else { return "端末内AIを使う補い方には、macOS 26以降と利用可能なApple Intelligenceが必要です。" }
        return generator.unavailableReason
    }

    init(
        generator: (any HaasPunctuationGenerating)?, timeout: Duration = .seconds(1.5),
        validator: @escaping HaasCandidateValidator = { candidate, original, _ in
            // 語尾が続く原文では、モデルの「、」を残したまま末尾の「。」だけ外してから検証する
            HaasPunctuationFormatter.validatedCandidate(
                HaasPunctuationFormatter.removingPeriodAfterUnfinishedEnding(candidate, original: original),
                preserving: original)
        }
    ) {
        self.generator = generator
        self.timeout = timeout
        self.validator = validator
    }

    func prewarm() {
        guard nativeRequestID == nil, unavailableReason == nil else { return }
        generator?.prewarm()
    }

    @discardableResult
    func submit(
        _ text: String, requestID: UUID, receivedAt: ContinuousClock.Instant = .now,
        protectedTerms: [String] = [], completion: @escaping (HaasPunctuationOutcome) -> Void
    ) -> Bool {
        let deadline = receivedAt.advanced(by: timeout)
        guard nativeRequestID == nil, let generator, generator.unavailableReason == nil,
            ContinuousClock.now < deadline
        else { return false }
        nativeRequestID = requestID
        let timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            self?.expire(requestID)
        }
        waiter = Waiter(id: requestID, text: text, protectedTerms: protectedTerms, deadline: deadline, timer: timer, completion: completion)
        nativeTask = Task { @MainActor [weak self, generator] in
            let output: String?
            do {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    self?.complete(requestID, output: nil)
                    return
                }
                output = try await generator.generate(text)
            } catch {
                output = nil
            }
            self?.complete(requestID, output: output)
        }
        return true
    }

    func cancel(requestID: UUID) {
        if waiter?.id == requestID {
            waiter?.timer.cancel()
            waiter = nil
        }
        if nativeRequestID == requestID { nativeTask?.cancel() }
    }

    private func expire(_ requestID: UUID) {
        guard let pending = waiter, pending.id == requestID else { return }
        waiter = nil
        nativeTask?.cancel()
        pending.completion(.timedOut)
    }

    /// output が nil なのは、期限までに始められなかったか、AI がエラーを返したとき
    private func complete(_ requestID: UUID, output: String?) {
        guard nativeRequestID == requestID else { return }
        nativeRequestID = nil
        nativeTask = nil
        guard let pending = waiter, pending.id == requestID else { return }
        waiter = nil
        pending.timer.cancel()
        let outcome: HaasPunctuationOutcome
        if ContinuousClock.now >= pending.deadline {
            outcome = .timedOut
        } else if let output {
            outcome = validator(output, pending.text, pending.protectedTerms).map { .formatted($0) } ?? .rejected
        } else {
            outcome = .failed
        }
        pending.completion(outcome)
    }
}
