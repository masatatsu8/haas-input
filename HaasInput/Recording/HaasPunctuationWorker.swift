import Foundation

@MainActor
protocol HaasPunctuationGenerating: AnyObject {
    var unavailableReason: String? { get }
    func prewarm()
    func generate(_ text: String) async throws -> String
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

    private struct Waiter {
        let id: UUID
        let text: String
        let protectedTerms: [String]
        let deadline: ContinuousClock.Instant
        let timer: Task<Void, Never>
        let completion: (String?) -> Void
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
            HaasPunctuationFormatter.validatedCandidate(candidate, preserving: original)
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
        protectedTerms: [String] = [], completion: @escaping (String?) -> Void
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
        pending.completion(nil)
    }

    private func complete(_ requestID: UUID, output: String?) {
        guard nativeRequestID == requestID else { return }
        nativeRequestID = nil
        nativeTask = nil
        guard let pending = waiter, pending.id == requestID else { return }
        waiter = nil
        pending.timer.cancel()
        let candidate = ContinuousClock.now < pending.deadline
            ? output.flatMap { validator($0, pending.text, pending.protectedTerms) } : nil
        pending.completion(candidate)
    }
}
