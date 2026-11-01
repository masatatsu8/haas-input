import Foundation

@MainActor
protocol HaasPunctuationGenerating: AnyObject {
    var unavailableReason: String? { get }
    func prewarm()
    func generate(_ text: String) async throws -> String
}

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

    private struct Waiter {
        let id: UUID
        let text: String
        let deadline: ContinuousClock.Instant
        let timer: Task<Void, Never>
        let completion: (String?) -> Void
    }

    private let generator: (any HaasPunctuationGenerating)?
    private let timeout: Duration
    private var nativeRequestID: UUID?
    private var nativeTask: Task<Void, Never>?
    private var waiter: Waiter?

    var unavailableReason: String? {
        guard let generator else { return "自然さ優先には macOS 26以降と利用可能な Apple Intelligence が必要です。" }
        return generator.unavailableReason
    }

    init(generator: (any HaasPunctuationGenerating)?, timeout: Duration = .seconds(1.5)) {
        self.generator = generator
        self.timeout = timeout
    }

    func prewarm() {
        guard nativeRequestID == nil, unavailableReason == nil else { return }
        generator?.prewarm()
    }

    @discardableResult
    func submit(
        _ text: String, requestID: UUID, receivedAt: ContinuousClock.Instant = .now,
        completion: @escaping (String?) -> Void
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
        waiter = Waiter(id: requestID, text: text, deadline: deadline, timer: timer, completion: completion)
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
            ? output.flatMap { HaasPunctuationFormatter.validatedCandidate($0, preserving: pending.text) } : nil
        pending.completion(candidate)
    }
}
