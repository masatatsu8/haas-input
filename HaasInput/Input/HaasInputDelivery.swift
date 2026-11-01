import AppKit
import ApplicationServices
import Carbon
import Combine
import Foundation
import os

@MainActor
struct HaasPasteTarget: HaasInputTargetChecking {
    let processID: pid_t
    let element: AXUIElement
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "HaasInputDelivery")

    static func capture() -> HaasPasteTarget? {
        readTarget(diagnoseFailure: true).target
    }

    var diagnosticAppIdentifier: String {
        NSRunningApplication(processIdentifier: processID)?.bundleIdentifier ?? "unknown"
    }

    func rejectionReason() -> String? {
        let read = Self.readTarget(diagnoseFailure: false)
        guard let current = read.target else { return read.reason }
        if processID != current.processID { return "app_changed" }
        return CFEqual(element, current.element) ? nil : "focus_changed"
    }

    private static func readTarget(diagnoseFailure: Bool) -> (target: HaasPasteTarget?, reason: String?) {
        let application = NSWorkspace.shared.frontmostApplication
        let appIdentifier = application?.bundleIdentifier ?? "unknown"
        var capturedRole = "unknown"
        func rejected(_ reason: String) -> (target: HaasPasteTarget?, reason: String?) {
            if diagnoseFailure {
                logger.notice("delivery phase=capture result=held reason=\(reason, privacy: .public) app=\(appIdentifier, privacy: .public) role=\(capturedRole, privacy: .public)")
            }
            return (nil, reason)
        }
        guard AXIsProcessTrusted() else { return rejected("accessibility_not_trusted") }
        guard !IsSecureEventInputEnabled() else { return rejected("secure_input") }
        guard NSApp.keyWindow?.isKeyWindow != true else { return rejected("own_window_focused") }
        guard let application else { return rejected("no_frontmost_app") }
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return rejected("own_app_focused") }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.10)
        var value: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        guard appResult == .success else { return rejected("app_ax_error_\(appResult.rawValue)") }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return rejected("app_focus_unavailable") }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.10)
        var role: CFTypeRef?
        var subrole: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard roleResult == .success else { return rejected("role_ax_error_\(roleResult.rawValue)") }
        capturedRole = role as? String ?? "unknown"
        guard let role = role as? String,
            [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
        else { return rejected("unsupported_role") }
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != kAXSecureTextFieldSubrole else { return rejected("secure_field") }
        guard NSApp.keyWindow?.isKeyWindow != true else { return rejected("own_window_focused") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            return rejected("app_changed_during_capture")
        }
        return (HaasPasteTarget(processID: application.processIdentifier, element: element), nil)
    }
}

enum HaasRecoveryCopyKind: Equatable { case pending, uncertain }

@MainActor
final class HaasInputDelivery: ObservableObject {
    static let shared = HaasInputDelivery(store: HaasRecoveryStore(), textPaster: HaasSystemTextPaster())

    @Published private var state = HaasRecoveryState()
    @Published private(set) var message = ""
    @Published private(set) var recoveryError: String?
    @Published private(set) var isPaused = true
    @Published private(set) var resumeCountdown: Int?
    private let store: HaasRecoveryStore
    private let textPaster: any HaasTextPasting
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "HaasInputDelivery")
    private var loadFailure: Error?
    private var persistenceFailure: Error?
    private var runningSessionID: UUID?
    private var pendingBeginID: UUID?
    private var target: (any HaasInputTargetChecking)?
    private var generation = UUID()
    private var drainTask: Task<Void, Never>?
    private var drainTaskID: UUID?
    private var resumeTask: Task<Void, Never>?
    private var formattingHolds: [String: UUID] = [:]

    var ledger: HaasSegmentLedger { state.active?.ledger ?? HaasSegmentLedger() }
    var archivedRecoveries: [HaasRecoveryRecord] { state.archives.reversed() }
    var hasUnreadableRecovery: Bool { loadFailure != nil }
    var hasUnsavedRecovery: Bool { persistenceFailure != nil }
    var hasRecovery: Bool {
        (isPaused && ledger.hasUnresolvedSegments) || hasUnreadableRecovery || hasUnsavedRecovery
    }
    var pendingText: String { ledger.pendingText }
    var uncertainText: String { ledger.uncertainText }
    private var nextReadySegment: HaasSegmentLedger.Segment? {
        guard let first = ledger.nextPendingSegment, formattingHolds[first.id] == nil else { return nil }
        return first
    }

    init(store: HaasRecoveryStore, textPaster: any HaasTextPasting) {
        self.store = store
        self.textPaster = textPaster
        do {
            let loaded = try store.load()
            state = loaded
            var recovered = loaded
            Self.archiveActive(in: &recovered)
            do {
                try store.save(recovered)
                state = recovered
            } catch {
                recordPersistenceFailure(error)
            }
        } catch {
            loadFailure = error
            recoveryError = error.localizedDescription
            message = "入力確認待ちを読み込めません。保存データは変更していません。"
        }
    }

    func begin(sessionID: UUID, target: (any HaasInputTargetChecking)?) async throws {
        if let loadFailure { throw loadFailure }
        if let persistenceFailure { throw persistenceFailure }
        guard pendingBeginID == nil, state.active?.id != sessionID else {
            throw HaasRecoveryError.invalidState
        }
        pendingBeginID = sessionID
        runningSessionID = nil
        let previousResume = resumeTask
        stopDelivery(message: "前回の入力確認待ちを保存しています。")
        let previousDrain = drainTask
        defer { if pendingBeginID == sessionID { pendingBeginID = nil } }
        await previousResume?.value
        await previousDrain?.value
        try Task.checkCancellation()
        guard pendingBeginID == sessionID else { throw CancellationError() }
        if let persistenceFailure { throw persistenceFailure }

        var candidate = state
        Self.archiveActive(in: &candidate)
        candidate.active = HaasRecoveryRecord(
            id: sessionID, createdAt: Date(),
            message: target == nil ? "入力先を確認できないため、まだ入力していません。" : ""
        )
        do {
            try store.save(candidate)
        } catch {
            recordPersistenceFailure(error)
            throw error
        }
        try Task.checkCancellation()
        guard pendingBeginID == sessionID else { throw CancellationError() }
        state = candidate
        runningSessionID = sessionID
        self.target = target
        isPaused = target == nil
        message = target == nil ? "入力先を確認できません。認識結果は保留し、コピーできます。" : ""
        recoveryError = nil
        logger.notice("delivery phase=begin session=\(sessionID.uuidString, privacy: .public) archives=\(candidate.archives.count, privacy: .public)")
    }

    @discardableResult
    func accept(sessionID: UUID, itemID: String, text: String, formattingHoldID: UUID? = nil) -> Bool {
        guard runningSessionID == sessionID, state.active?.id == sessionID, pendingBeginID == nil else {
            logger.notice("delivery phase=accept result=stale session=\(sessionID.uuidString, privacy: .public)")
            return false
        }
        var candidate = state
        guard candidate.active?.ledger.append(id: itemID, text: text) == true else { return false }
        if hasUnsavedRecovery {
            state = candidate
            return false
        }
        if let formattingHoldID { formattingHolds[itemID] = formattingHoldID }
        guard save(candidate, retainingIncomingText: true) else { return false }
        startDrain()
        return true
    }

    func completeHeldFormatting(sessionID: UUID, itemID: String, requestID: UUID, text: String) -> Bool {
        guard runningSessionID == sessionID, state.active?.id == sessionID, pendingBeginID == nil,
            formattingHolds[itemID] == requestID, !hasUnsavedRecovery
        else { return false }
        var candidate = state
        guard candidate.active?.ledger.replacePendingText(text, for: itemID) == true else { return false }
        if candidate != state, !save(candidate) { return false }
        formattingHolds.removeValue(forKey: itemID)
        startDrain()
        return true
    }

    func finish(sessionID: UUID) async {
        guard state.active?.id == sessionID else { return }
        await drainTask?.value
        if runningSessionID == sessionID { runningSessionID = nil }
    }

    func cancel(sessionID: UUID, message: String?) {
        if pendingBeginID == sessionID {
            pendingBeginID = nil
            generation = UUID()
        }
        if runningSessionID == sessionID { runningSessionID = nil }
        guard state.active?.id == sessionID, pendingBeginID == nil else { return }
        stopDelivery(message: message ?? self.message)
    }

    func pause(sessionID: UUID, message: String) {
        guard state.active?.id == sessionID, pendingBeginID == nil else { return }
        stopDelivery(message: message)
    }

    func attachTranscription(sessionID: UUID, transcriptionID: UUID) {
        var candidate = state
        if candidate.active?.id == sessionID {
            candidate.active?.transcriptionID = transcriptionID
        } else if let index = candidate.archives.firstIndex(where: { $0.id == sessionID }) {
            candidate.archives[index].transcriptionID = transcriptionID
        } else {
            return
        }
        if hasUnsavedRecovery { state = candidate }
        else { _ = save(candidate) }
    }

    func scheduleResume() {
        guard let recordID = state.active?.id, pendingBeginID == nil,
            !pendingText.isEmpty, uncertainText.isEmpty, !hasUnreadableRecovery, !hasUnsavedRecovery
        else { return }
        stopDelivery(message: "3 秒以内に、入力するアプリのテキスト欄を選んでください。")
        let reservation = generation
        resumeCountdown = 3
        resumeTask = Task { @MainActor [weak self] in
            do {
                for remaining in (0..<3).reversed() {
                    try await Task.sleep(for: .seconds(1))
                    guard let self, self.generation == reservation, self.state.active?.id == recordID else { return }
                    self.resumeCountdown = remaining == 0 ? nil : remaining
                }
            } catch { return }
            guard let self, self.generation == reservation, self.state.active?.id == recordID,
                self.pendingBeginID == nil, !Task.isCancelled
            else { return }
            self.resumeTask = nil
            guard let target = HaasPasteTarget.capture() else {
                self.message = "入力先を確認できませんでした。再開を予約して外部のテキスト欄を選ぶか、未入力分をコピーしてください。"
                return
            }
            self.target = target
            self.isPaused = false
            self.message = ""
            self.startDrain()
        }
    }

    func cancelScheduledResume() {
        guard resumeTask != nil else { return }
        stopDelivery(message: "再開の予約を取り消しました。未入力分は保留しています。")
    }

    func pauseForPanelDismissal() {
        if resumeTask != nil || drainTask != nil || !formattingHolds.isEmpty {
            stopDelivery(message: "入力の再開を取り消しました。未入力分は保留しています。")
        }
    }

    func pauseForNewRecording() {
        if resumeTask != nil || drainTask != nil || !formattingHolds.isEmpty {
            stopDelivery(message: message)
        }
    }

    func copyPending() {
        guard !pendingText.isEmpty, pendingBeginID == nil else { return }
        stopDelivery(message: "未入力分をコピーしました。必要な場所へ貼り付けてください。")
        guard textPaster.copy(pendingText) else {
            recoveryError = "クリップボードへコピーできませんでした。保留文は残しています。"
            return
        }
        var candidate = state
        candidate.active?.ledger.markPendingAsCopied()
        _ = save(candidate)
    }

    func acknowledgeUncertainInput() {
        guard pendingBeginID == nil else { return }
        var candidate = state
        candidate.active?.ledger.acknowledgeUncertainSegments()
        if save(candidate) {
            message = pendingText.isEmpty ? "入力確認を完了しました。" : "未入力分を再開するか、コピーしてください。"
        }
    }

    func copyArchivedRecovery(id: UUID, kind: HaasRecoveryCopyKind) {
        guard let record = state.archives.first(where: { $0.id == id }) else { return }
        let text = kind == .pending ? record.ledger.pendingText : record.ledger.uncertainText
        guard !text.isEmpty else { return }
        if !textPaster.copy(text) {
            recoveryError = "クリップボードへコピーできませんでした。入力確認待ちは残しています。"
        } else if !hasUnreadableRecovery, !hasUnsavedRecovery {
            recoveryError = nil
        }
    }

    func acknowledgeArchivedRecovery(id: UUID) {
        guard let index = state.archives.firstIndex(where: { $0.id == id }) else { return }
        var candidate = state
        candidate.archives.remove(at: index)
        _ = save(candidate)
    }

    private func stopDelivery(message: String) {
        resumeTask?.cancel()
        resumeTask = nil
        resumeCountdown = nil
        formattingHolds.removeAll()
        generation = UUID()
        isPaused = true
        self.message = message
        if pendingBeginID == nil { state.active?.message = message }
    }

    private func startDrain() {
        guard drainTask == nil, !isPaused, !hasUnsavedRecovery, pendingBeginID == nil,
            let recordID = state.active?.id, nextReadySegment != nil
        else { return }
        let drainGeneration = generation
        let taskID = UUID()
        drainTaskID = taskID
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.drainTaskID == taskID {
                    self.drainTask = nil
                    self.drainTaskID = nil
                    if self.state.active?.id == recordID, !self.isPaused,
                        self.pendingBeginID == nil, self.nextReadySegment != nil
                    { self.startDrain() }
                }
            }
            while self.state.active?.id == recordID, self.generation == drainGeneration,
                !self.isPaused, self.pendingBeginID == nil,
                let segment = self.nextReadySegment
            {
                guard let target = self.target else {
                    self.stopDelivery(message: "入力先が変わったため、この録音の未入力分を保留しました。")
                    break
                }
                if let reason = target.rejectionReason() {
                    self.logger.notice("delivery phase=before-command result=held session=\(recordID.uuidString, privacy: .public) segment=\(segment.id, privacy: .public) reason=\(reason, privacy: .public)")
                    self.stopDelivery(message: "入力先が変わったため、この録音の未入力分を保留しました。")
                    break
                }
                var posting = self.state
                posting.active?.ledger.setDisposition(.posting, for: segment.id)
                guard self.save(posting) else { break }
                self.logger.notice("delivery phase=before-command session=\(recordID.uuidString, privacy: .public) segment=\(segment.id, privacy: .public) generation=\(drainGeneration.uuidString, privacy: .public) app=\(target.diagnosticAppIdentifier, privacy: .public)")
                var guardFailure: String?
                let outcome = await self.textPaster.paste(segment.text) { [weak self] in
                    guard let self else { return false }
                    if self.state.active?.id != recordID { guardFailure = "session_changed" }
                    else if self.generation != drainGeneration { guardFailure = "generation_changed" }
                    else if self.isPaused { guardFailure = "paused" }
                    else if let reason = target.rejectionReason() { guardFailure = reason }
                    else { return true }
                    return false
                }
                guard self.state.active?.id == recordID else {
                    self.logger.error("delivery phase=after-command result=stale session=\(recordID.uuidString, privacy: .public)")
                    return
                }
                self.logger.notice("delivery phase=after-command session=\(recordID.uuidString, privacy: .public) segment=\(segment.id, privacy: .public) result=\(String(describing: outcome.result), privacy: .public) guard=\(guardFailure ?? "none", privacy: .public)")
                var completed = self.state
                let status: HaasSegmentLedger.Disposition
                let statusMessage: String?
                switch outcome.result {
                case .commandPosted:
                    status = .posted
                    statusMessage = nil
                case .commandNotPosted:
                    status = .pending
                    statusMessage = "入力できなかった区間を保留しました。入力先とアクセシビリティ権限を確認してください。"
                case .clipboardChanged:
                    status = .pending
                    statusMessage = "入力前にクリップボードが変わったため、この区間を保留しました。"
                case .commandPartiallyPosted:
                    status = .uncertain
                    statusMessage = "入力済みか確認が必要な区間があります。この区間は自動再送しません。"
                }
                completed.active?.ledger.setDisposition(status, for: segment.id)
                if let statusMessage { completed.active?.message = statusMessage }
                if !self.save(completed) {
                    var retained = self.state
                    retained.active?.ledger.recoverInterruptedPaste()
                    self.state = retained
                    break
                }
                if let statusMessage, self.pendingBeginID == nil {
                    self.stopDelivery(message: statusMessage)
                }
            }
        }
    }

    private func save(_ candidate: HaasRecoveryState, retainingIncomingText: Bool = false) -> Bool {
        do {
            try store.save(candidate)
            state = candidate
            persistenceFailure = nil
            recoveryError = nil
            return true
        } catch {
            if retainingIncomingText { state = candidate }
            recordPersistenceFailure(error)
            return false
        }
    }

    private func recordPersistenceFailure(_ error: Error) {
        persistenceFailure = error
        recoveryError = error.localizedDescription
        stopDelivery(message: "入力確認待ちを保存できません。表示中の本文をコピーして保管してください。新しい録音は開始しません。")
        logger.error("delivery phase=persist result=failed error=\(error.localizedDescription, privacy: .public)")
    }

    private static func archiveActive(in state: inout HaasRecoveryState) {
        guard var record = state.active else { return }
        record.ledger = record.ledger.unresolvedArchive
        if record.ledger.hasUnresolvedSegments { state.archives.append(record) }
        state.active = nil
    }
}
