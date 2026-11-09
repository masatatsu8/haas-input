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

    private static let manualAccessibility = "AXManualAccessibility" as CFString
    private static var webAccessibility: (application: NSRunningApplication, element: AXUIElement)?

    static func prepareForegroundAccessibility() {
        let application = NSWorkspace.shared.frontmostApplication
        if let prepared = webAccessibility, prepared.application != application {
            releaseForegroundAccessibility()
        }
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
            let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            webAccessibility == nil
        else { return }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.10)
        // Keep accessibility enabled if another client already requested it.
        guard boolAttribute(manualAccessibility, from: app).value == false,
            NSWorkspace.shared.frontmostApplication == application,
            !IsSecureEventInputEnabled(),
            AXUIElementSetAttributeValue(app, manualAccessibility, kCFBooleanTrue) == .success
        else { return }
        webAccessibility = (application, app)
    }

    static func releaseForegroundAccessibility() {
        guard let prepared = webAccessibility else { return }
        webAccessibility = nil
        if !prepared.application.isTerminated {
            let result = AXUIElementSetAttributeValue(prepared.element, manualAccessibility, kCFBooleanFalse)
            if result != .success {
                logger.notice("delivery phase=web-access-restore result=\(result.rawValue, privacy: .public)")
            }
        }
    }

    static func capture() -> HaasPasteTarget? {
        let read = readTarget(diagnoseFailure: true)
        if read.target == nil { prepareForegroundAccessibility() }
        return read.target
    }

    var diagnosticAppIdentifier: String {
        NSRunningApplication(processIdentifier: processID)?.bundleIdentifier ?? "unknown"
    }

    func rejectionReason() -> String? {
        let read = Self.readTarget(diagnoseFailure: false, expectedPID: processID)
        guard let current = read.target else { return read.reason }
        return CFEqual(element, current.element) ? nil : "focus_changed"
    }

    func fieldState() -> HaasFieldState {
        AXUIElementSetMessagingTimeout(element, 0.10)
        var value: CFTypeRef?
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
            let text = value as? String,
            AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
            let range, CFGetTypeID(range) == AXValueGetTypeID()
        else { return .unreadable }
        var selected = CFRange()
        guard AXValueGetValue(range as! AXValue, .cfRange, &selected) else { return .unreadable }
        return HaasFieldState.make(value: text, selectedRange: selected)
    }

    func activate() -> Bool {
        NSRunningApplication(processIdentifier: processID)?.activate() ?? false
    }

    private static func readTarget(
        diagnoseFailure: Bool, expectedPID: pid_t? = nil
    ) -> (target: HaasPasteTarget?, reason: String?) {
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
        let pid = application.processIdentifier
        if let expectedPID, expectedPID != pid { return rejected("app_changed") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.10)
        let focus = readFocus(in: app)
        guard let element = focus.element else { return rejected("app_focus_unavailable_\(focus.error.rawValue)") }
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == pid else {
            return rejected("focus_owner_mismatch")
        }
        AXUIElementSetMessagingTimeout(element, 0.10)
        var roleValue: CFTypeRef?
        var subrole: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        guard roleResult == .success, let role = roleValue as? String else {
            return rejected("role_unavailable_\(roleResult.rawValue)")
        }
        capturedRole = role
        let subroleResult = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard isOptionalAttributeResult(subroleResult) else {
            return rejected("subrole_ax_error_\(subroleResult.rawValue)")
        }
        guard subrole as? String != kAXSecureTextFieldSubrole else { return rejected("secure_field") }
        let protectedContent = boolAttribute("AXProtectedContent" as CFString, from: element)
        guard isOptionalAttributeResult(protectedContent.error) else {
            return rejected("protection_ax_error_\(protectedContent.error.rawValue)")
        }
        guard protectedContent.value != true else { return rejected("secure_field") }
        let editable = boolAttribute("AXEditable" as CFString, from: element)
        guard isOptionalAttributeResult(editable.error) else {
            return rejected("editability_ax_error_\(editable.error.rawValue)")
        }
        let standardRole = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
        guard editable.value ?? standardRole else { return rejected("unsupported_or_read_only_field") }
        guard let confirmed = readFocus(in: app).element, CFEqual(confirmed, element) else {
            return rejected("focus_changed_during_capture")
        }
        guard !IsSecureEventInputEnabled() else { return rejected("secure_input") }
        guard NSApp.keyWindow?.isKeyWindow != true else { return rejected("own_window_focused") }
        guard NSWorkspace.shared.frontmostApplication == application else {
            return rejected("app_changed_during_capture")
        }
        return (HaasPasteTarget(processID: pid, element: element), nil)
    }

    private static func readFocus(in app: AXUIElement) -> (element: AXUIElement?, error: AXError) {
        let appFocus = focusedElement(in: app)
        if appFocus.element != nil { return appFocus }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.10)
        if let focused = focusedElement(in: system).element { return (focused, .success) }
        return appFocus
    }

    private static func focusedElement(in root: AXUIElement) -> (element: AXUIElement?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (nil, error)
        }
        return (value as! AXUIElement, error)
    }

    private static func boolAttribute(
        _ attribute: CFString, from element: AXUIElement
    ) -> (value: Bool?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else { return (nil, error) }
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID(), let number = value as? NSNumber else {
            return (nil, .failure)
        }
        return (number.boolValue, .success)
    }

    private static func isOptionalAttributeResult(_ error: AXError) -> Bool {
        error == .success || error == .attributeUnsupported || error == .noValue || error == .notImplemented
    }
}

extension HaasFieldState {
    /// AX の値と選択範囲 (UTF-16 の位置) から作る。範囲が値の外や、範囲の始まり・終わりが
    /// Unicode スカラーの途中なら .unreadable
    static func make(value: String, selectedRange: CFRange) -> HaasFieldState {
        let units = value.utf16.count
        guard selectedRange.location >= 0, selectedRange.length >= 0,
            selectedRange.location <= units, selectedRange.length <= units - selectedRange.location
        else { return .unreadable }
        let caret = String.Index(utf16Offset: selectedRange.location, in: value)
        let selectionEnd = String.Index(utf16Offset: selectedRange.location + selectedRange.length, in: value)
        guard caret.samePosition(in: value.unicodeScalars) != nil,
            selectionEnd.samePosition(in: value.unicodeScalars) != nil
        else { return .unreadable }
        return .readable(
            textBeforeCaret: String(value[..<caret]), textAfterCaret: String(value[selectionEnd...]),
            selectionLength: selectedRange.length)
    }
}

enum HaasRecoveryCopyKind: Equatable { case pending, uncertain }

/// 直前の録音1回分の入力。訂正の判定に使う
struct HaasDeliveredInput {
    let sessionID: UUID
    let transcriptionID: UUID?
    let text: String
    /// 区切りがすべて posted で、かつ1つ以上ある。録音の途中で入力先を取り直した回は false
    let allSegmentsPosted: Bool
    let target: (any HaasInputTargetChecking)?
    /// この録音の開始で始めた見張りの印 (別の回の印は返さない)
    let watchToken: UUID?
    /// この録音の最初の区切りを貼る直前の欄の状態。記録がなければ nil
    let insertionBaseline: HaasInsertionBaseline?
    /// 入力し終えた時刻。記録がなければ録音を始めた時刻、それもなければ直せる時間を過ぎたものとして .distantPast
    let deliveredAt: Date
}

@MainActor
protocol HaasDeliveredInputProviding: AnyObject {
    var lastDeliveredInput: HaasDeliveredInput? { get }
}

@MainActor
final class HaasInputDelivery: ObservableObject, HaasDeliveredInputProviding {
    static let shared = HaasInputDelivery(
        store: HaasRecoveryStore(), textPaster: HaasSystemTextPaster(), inputMonitor: HaasUserInputMonitor.shared)

    @Published private var state = HaasRecoveryState()
    @Published private(set) var message = ""
    @Published private(set) var recoveryError: String?
    @Published private(set) var isPaused = true
    @Published private(set) var resumeCountdown: Int?
    private let store: HaasRecoveryStore
    private let textPaster: any HaasTextPasting
    private let inputMonitor: any HaasInputWatching
    /// 録音の開始で始めた、入力後の操作の見張りの印
    private(set) var watchToken: UUID?
    /// watchToken を始めた録音。begin が失敗しても前回の印と記録の組が崩れないように持つ
    private var watchSessionID: UUID?
    /// 再開で入力先を取り直した録音。前の入力先に入れた分は今の入力先にないので、置き換えに使わせない
    private var retargetedSessionID: UUID?
    /// 録音の最初の区切りを貼る直前に読んだ欄の状態と、その録音
    private var insertionBaseline: (sessionID: UUID, baseline: HaasInsertionBaseline)?
    /// 録音の入力を終えた時刻と、その録音。区切りを貼り終えたときと、finish で貼り付けの完了を待った後に記録し直す
    private var deliveredAt: (sessionID: UUID, date: Date)?
    private let captureTarget: @MainActor () -> (any HaasInputTargetChecking)?
    private let now: () -> Date
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

    /// 直前の録音の入力。記録がない、録音中、開始の途中、貼り付け中は nil
    var lastDeliveredInput: HaasDeliveredInput? {
        guard let record = state.active, runningSessionID == nil, pendingBeginID == nil, drainTask == nil else {
            return nil
        }
        let segments = record.ledger.segments
        let finishedAt = deliveredAt.flatMap { $0.sessionID == record.id ? $0.date : nil }
        return HaasDeliveredInput(
            sessionID: record.id, transcriptionID: record.transcriptionID, text: record.ledger.fullText,
            allSegmentsPosted: !segments.isEmpty && segments.allSatisfy { $0.disposition == .posted }
                && retargetedSessionID != record.id,
            target: target, watchToken: watchSessionID == record.id ? watchToken : nil,
            insertionBaseline: insertionBaseline?.sessionID == record.id ? insertionBaseline?.baseline : nil,
            deliveredAt: finishedAt ?? record.createdAt ?? .distantPast)
    }

    private var nextReadySegment: HaasSegmentLedger.Segment? {
        guard let first = ledger.nextPendingSegment, formattingHolds[first.id] == nil else { return nil }
        return first
    }

    init(
        store: HaasRecoveryStore, textPaster: any HaasTextPasting,
        inputMonitor: any HaasInputWatching = HaasUserInputMonitor.shared,
        captureTarget: @escaping @MainActor () -> (any HaasInputTargetChecking)? = { HaasPasteTarget.capture() },
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.textPaster = textPaster
        self.inputMonitor = inputMonitor
        self.captureTarget = captureTarget
        self.now = now
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
            id: sessionID, createdAt: now(),
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
        watchToken = inputMonitor.startWatching()
        watchSessionID = sessionID
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
        if state.active?.id == sessionID { deliveredAt = (sessionID, now()) }
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
            guard let target = self.captureTarget() else {
                self.message = "入力先を確認できませんでした。再開を予約して外部のテキスト欄を選ぶか、未入力分をコピーしてください。"
                return
            }
            // 入力先を取り直したので、この録音の入力はどれも置き換えに使わない。
            // 自分の窓での操作や ⌘Tab は見張りで見えないことがあるため、見張りも信頼しない
            self.retargetedSessionID = recordID
            self.inputMonitor.invalidate()
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

    /// 入力の後の見張りを信頼しなくする。この配信を通さずに貼るとき (直前の認識結果の入力など) に呼ぶ
    func invalidateInputWatch() {
        inputMonitor.invalidate()
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
                // 最初の区切りを貼る直前の欄を記録する。訂正では、この中身に入れた文を足したものと
                // ちょうど一致するときだけ消す (末尾が同じだけでは今回入れた証明にならない)
                if self.insertionBaseline?.sessionID != recordID {
                    let baseline: HaasInsertionBaseline
                    switch target.fieldState() {
                    case let .readable(textBeforeCaret, textAfterCaret, selectionLength) where selectionLength == 0:
                        baseline = .readable(textBeforeInsertion: textBeforeCaret, textAfterInsertion: textAfterCaret)
                    case .readable, .unreadable:
                        // 選択範囲があると貼り付けで消える文字があるので、読めなかったものとして扱う
                        baseline = .unreadable
                    }
                    self.insertionBaseline = (recordID, baseline)
                }
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
                    self.deliveredAt = (recordID, self.now())
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
