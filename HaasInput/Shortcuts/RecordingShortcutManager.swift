import AppKit
import Combine
import Foundation
import os

@MainActor
final class RecordingShortcutManager: ObservableObject {
    // 録音のショートカットの選択や方式が変わると、入力後の見張りの除外の一覧が古くなるので、見張りを打ち切る
    @Published var primaryRecordingShortcut: ShortcutSelection {
        didSet {
            invalidateInputWatch()
            UserDefaults.standard.set(primaryRecordingShortcut.rawValue, forKey: "primaryRecordingShortcut")
            refreshShortcutMonitoring(reason: "primary-selection")
        }
    }
    @Published var secondaryRecordingShortcut: ShortcutSelection {
        didSet {
            invalidateInputWatch()
            if secondaryRecordingShortcut == .none { ShortcutStore.setShortcut(nil, for: .secondaryRecording) }
            UserDefaults.standard.set(secondaryRecordingShortcut.rawValue, forKey: "secondaryRecordingShortcut")
            refreshShortcutMonitoring(reason: "secondary-selection")
        }
    }
    @Published var primaryRecordingShortcutMode: Mode {
        didSet {
            invalidateInputWatch()
            UserDefaults.standard.set(primaryRecordingShortcutMode.rawValue, forKey: "primaryRecordingShortcutMode")
            shortcutModeHandler.resetShortcutState(for: .primaryRecording)
            shortcutMonitor.resetShortcutStates(for: [.primaryRecording])
            shortcutMonitor.updateStandaloneModifierActions(standaloneModifierActions)
        }
    }
    @Published var secondaryRecordingShortcutMode: Mode {
        didSet {
            invalidateInputWatch()
            UserDefaults.standard.set(secondaryRecordingShortcutMode.rawValue, forKey: "secondaryRecordingShortcutMode")
            shortcutModeHandler.resetShortcutState(for: .secondaryRecording)
            shortcutMonitor.resetShortcutStates(for: [.secondaryRecording])
            shortcutMonitor.updateStandaloneModifierActions(standaloneModifierActions)
        }
    }

    enum Mode: String, CaseIterable {
        case toggle
        case pushToTalk
        case hybrid
        case doubleTap

        var displayName: String {
            switch self {
            case .toggle: return "押すたびに開始・停止"
            case .pushToTalk: return "押している間だけ録音"
            case .hybrid: return "短押しと長押しを併用"
            case .doubleTap: return "2回押して開始・停止"
            }
        }
    }

    enum ShortcutSelection: String, CaseIterable {
        case none
        case custom

        var displayName: String {
            switch self {
            case .none: return "使用しない"
            case .custom: return "指定する"
            }
        }
    }

    private let recordingState: @MainActor () -> RecordingState
    private let isRecorderVisible: @MainActor () -> Bool
    private let pasteLastTranscription: @MainActor () -> Void
    private let openHistory: @MainActor () -> Void
    private let correctLastInput: @MainActor () -> Void
    private let invalidateInputWatch: @MainActor () -> Void
    private let shortcutMonitor = ShortcutMonitor(owner: "recording")
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private let recorderPanelShortcutManager: RecorderPanelShortcutManager
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var shortcutChangeObserver: NSObjectProtocol?

    init(
        recordingState: @escaping @MainActor () -> RecordingState,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        activeRecordingStartID: @escaping @MainActor () -> UUID?,
        startHeldRecording: @escaping @MainActor () -> UUID?,
        finishHeldRecording: @escaping @MainActor (UUID) -> Void,
        cancelHeldRecording: @escaping @MainActor (UUID) async -> Void,
        toggleRecording: @escaping @MainActor () async -> Void,
        cancelRecording: @escaping @MainActor () async -> Void,
        pasteLastTranscription: @escaping @MainActor () -> Void,
        openHistory: @escaping @MainActor () -> Void,
        correctLastInput: @escaping @MainActor () -> Void,
        invalidateInputWatch: @escaping @MainActor () -> Void
    ) {
        ShortcutMigration.migrateLegacyShortcutsIfNeeded()
        primaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(action: .primaryRecording, allowsNone: false)
        secondaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(action: .secondaryRecording, allowsNone: true)
        primaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(for: .primaryRecording)
        secondaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(for: .secondaryRecording)
        self.recordingState = recordingState
        self.isRecorderVisible = isRecorderVisible
        self.pasteLastTranscription = pasteLastTranscription
        self.openHistory = openHistory
        self.correctLastInput = correctLastInput
        self.invalidateInputWatch = invalidateInputWatch
        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: {
                recordingState() != .transcribing && recordingState() != .busy
            },
            isRecorderVisible: isRecorderVisible,
            recordingState: recordingState,
            activeRecordingStartID: activeRecordingStartID,
            isShortcutHeld: { ShortcutStore.shortcut(for: $0)?.isCurrentlyPressed == true },
            startHeldRecording: startHeldRecording,
            finishHeldRecording: finishHeldRecording,
            toggleRecording: toggleRecording,
            cancelRecording: cancelHeldRecording
        )
        shortcutModeHandler = handler
        recorderPanelShortcutManager = RecorderPanelShortcutManager(
            isRecorderVisible: isRecorderVisible,
            cancelRecording: cancelRecording,
            heldRecordingShortcut: { handler.heldRecordingShortcut }
        )
        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            let action = (notification.object as? ShortcutAction)?.storageName ?? "unknown"
            Task { @MainActor in self?.refreshShortcutMonitoring(reason: "store-change.\(action)") }
        }
        setupLifecycleDiagnostics()
        ShortcutDiagnostics.logSessionStart()
        ShortcutDiagnostics.setRecordingContext { [weak self] in
            guard let self else { return "unavailable" }
            return "state=\(self.recordingState()) visible=\(self.isRecorderVisible()) primarySelection=\(self.primaryRecordingShortcut.rawValue) primaryMode=\(self.primaryRecordingShortcutMode.rawValue) secondarySelection=\(self.secondaryRecordingShortcut.rawValue) secondaryMode=\(self.secondaryRecordingShortcutMode.rawValue) \(self.shortcutModeHandler.diagnosticSummary)"
        }
        ShortcutDiagnostics.observeEnvironment(reason: "startup", force: true)
        refreshShortcutMonitoring(reason: "startup")
    }

    private func refreshShortcutMonitoring(reason: String) {
        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.globalUtilityActions)
        var recordingActions = Set<ShortcutAction>()
        if primaryRecordingShortcut == .custom, let shortcut = ShortcutStore.shortcut(for: .primaryRecording) {
            shortcuts[.primaryRecording] = shortcut
            recordingActions.insert(.primaryRecording)
        }
        if secondaryRecordingShortcut == .custom, let shortcut = ShortcutStore.shortcut(for: .secondaryRecording) {
            shortcuts[.secondaryRecording] = shortcut
            recordingActions.insert(.secondaryRecording)
        }
        shortcutMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: recordingActions,
            standaloneModifierActions: standaloneModifierActions,
            onShortcutDown: { [weak self] action, eventTime in
                guard let self, let mode = self.recordingMode(for: action) else { return }
                await self.shortcutModeHandler.handleShortcutDown(action: action, eventTime: eventTime, mode: mode)
            },
            onShortcutUp: { [weak self] action, eventTime in
                guard let self else { return }
                if let mode = self.recordingMode(for: action) {
                    await self.shortcutModeHandler.handleShortcutUp(action: action, eventTime: eventTime, mode: mode)
                } else {
                    self.handleUtilityShortcut(action)
                }
            },
            onShortcutInterrupted: { [weak self] action, pressedAt in
                guard let self, self.recordingMode(for: action) != nil else { return }
                await self.shortcutModeHandler.handleInterruption(action: action, pressedAt: pressedAt)
            },
            onStandaloneModifierChord: { [weak self] action in
                self?.shortcutModeHandler.clearPendingDoubleTap(for: action)
            },
            onMonitoringReset: { [weak self] actions in
                self?.shortcutModeHandler.resetShortcutStates(for: actions)
            },
            onMissedRelease: { [weak self] action in
                self?.shortcutModeHandler.recoverMissedRelease(for: action)
            },
            reason: reason
        )
        recorderPanelShortcutManager.refresh(reason: reason)
    }

    private var standaloneModifierActions: Set<ShortcutAction> {
        var actions = Set<ShortcutAction>()
        if primaryRecordingShortcutMode == .toggle || primaryRecordingShortcutMode == .doubleTap {
            actions.insert(.primaryRecording)
        }
        if secondaryRecordingShortcutMode == .toggle || secondaryRecordingShortcutMode == .doubleTap {
            actions.insert(.secondaryRecording)
        }
        return actions
    }

    private func recordingMode(for action: ShortcutAction) -> Mode? {
        switch action {
        case .primaryRecording: return primaryRecordingShortcutMode
        case .secondaryRecording: return secondaryRecordingShortcutMode
        default: return nil
        }
    }

    /// ショートカットに一致したキー入力は ShortcutMonitor が止めるので、全体の見張りには届かない。
    /// 訂正以外のユーティリティ操作は、実行する前に見張りを打ち切る。
    static func invalidatesInputWatch(_ action: ShortcutAction) -> Bool {
        switch action {
        case .pasteLastTranscription, .openQuickHistory: return true
        default: return false
        }
    }

    private func handleUtilityShortcut(_ action: ShortcutAction) {
        if Self.invalidatesInputWatch(action) { invalidateInputWatch() }
        switch action {
        case .pasteLastTranscription: pasteLastTranscription()
        case .openQuickHistory: openHistory()
        case .correctLastInput: correctLastInput()
        default: break
        }
    }

    var isShortcutConfigured: Bool {
        primaryRecordingShortcut != .none && ShortcutStore.shortcut(for: .primaryRecording) != nil
            && (secondaryRecordingShortcut == .none || ShortcutStore.shortcut(for: .secondaryRecording) != nil)
    }

    func updateShortcutStatus() {
        refreshShortcutMonitoring(reason: "status-update")
    }

    func updateRecorderState() {
        recorderPanelShortcutManager.refresh(reason: "recording-state.\(recordingState())")
    }

    func stopMonitoring() {
        shortcutMonitor.stop(reason: "shutdown")
        recorderPanelShortcutManager.stop()
    }

    private func setupLifecycleDiagnostics() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, reason) in [
            (NSWorkspace.willSleepNotification, "sleep"),
            (NSWorkspace.didWakeNotification, "wake"),
            (NSWorkspace.sessionDidResignActiveNotification, "session-inactive"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session-active"),
        ] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in ShortcutDiagnostics.observeEnvironment(reason: reason, force: true) }
            })
        }
    }

    isolated deinit {
        if let shortcutChangeObserver { NotificationCenter.default.removeObserver(shortcutChangeObserver) }
        for observer in lifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        stopMonitoring()
    }
}

@MainActor
final class RecordingShortcutModeHandler {
    // Tap callbacks read this snapshot without waiting for the main actor.
    private nonisolated let heldShortcut = OSAllocatedUnfairLock<Shortcut?>(initialState: nil)

    nonisolated var heldRecordingShortcut: Shortcut? { heldShortcut.withLock { $0 } }

    private let canHandleShortcutAction: @MainActor () -> Bool
    private let isRecorderVisible: @MainActor () -> Bool
    private let recordingState: @MainActor () -> RecordingState
    private let activeRecordingStartID: @MainActor () -> UUID?
    private let isShortcutHeld: @MainActor (ShortcutAction) -> Bool
    private let startHeldRecording: @MainActor () -> UUID?
    private let finishHeldRecording: @MainActor (UUID) -> Void
    private let toggleRecording: @MainActor () async -> Void
    private let cancelRecording: @MainActor (UUID) async -> Void

    private var shortcutPressStartTime: TimeInterval?
    private var isHandsFreeRecording = false
    private var isShortcutPressed = false
    private var activeRecordingShortcutAction: ShortcutAction?
    private var activeRecordingShortcutMode: RecordingShortcutManager.Mode?
    private var interruptedRecordingActions: [ShortcutAction: TimeInterval] = [:]
    private var activeShortcutCanCancelAccidentalStart = false
    private var activeShortcutIsDoubleTap = false
    private var activeHeldRecordingID: UUID?
    private var stateRevision: UInt64 = 0
    private var pendingDoubleTapReleaseTimes: [ShortcutAction: TimeInterval] = [:]

    private let hybridPressThreshold: TimeInterval = 0.5
    private let doubleTapThreshold: TimeInterval = 0.7

    init(
        canHandleShortcutAction: @escaping @MainActor () -> Bool,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        recordingState: @escaping @MainActor () -> RecordingState,
        activeRecordingStartID: @escaping @MainActor () -> UUID?,
        isShortcutHeld: @escaping @MainActor (ShortcutAction) -> Bool,
        startHeldRecording: @escaping @MainActor () -> UUID?,
        finishHeldRecording: @escaping @MainActor (UUID) -> Void,
        toggleRecording: @escaping @MainActor () async -> Void,
        cancelRecording: @escaping @MainActor (UUID) async -> Void
    ) {
        self.canHandleShortcutAction = canHandleShortcutAction
        self.isRecorderVisible = isRecorderVisible
        self.recordingState = recordingState
        self.activeRecordingStartID = activeRecordingStartID
        self.isShortcutHeld = isShortcutHeld
        self.startHeldRecording = startHeldRecording
        self.finishHeldRecording = finishHeldRecording
        self.toggleRecording = toggleRecording
        self.cancelRecording = cancelRecording
    }

    func reset() {
        heldShortcut.withLock { $0 = nil }
        stateRevision &+= 1
        isShortcutPressed = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = false
        activeRecordingShortcutAction = nil
        activeRecordingShortcutMode = nil
        interruptedRecordingActions.removeAll()
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        activeHeldRecordingID = nil
        clearPendingDoubleTaps()
    }

    func clearPendingDoubleTaps() {
        pendingDoubleTapReleaseTimes.removeAll()
    }

    func clearPendingDoubleTap(for action: ShortcutAction) {
        if pendingDoubleTapReleaseTimes.removeValue(forKey: action) != nil {
            logDecision(action, phase: "double-tap", result: "pending-cleared")
        }
    }

    func resetShortcutState(for action: ShortcutAction) {
        resetShortcutStates(for: [action])
    }

    func resetShortcutStates(for actions: Set<ShortcutAction>) {
        resetShortcutStates(for: actions, preservingRecording: false)
    }

    func recoverMissedRelease(for action: ShortcutAction) {
        logDecision(action, phase: "recovery", result: "missed-release")
        // A missed release still ends a push-to-talk recording.
        resetShortcutStates(for: [action], preservingRecording: activeRecordingShortcutMode != .pushToTalk)
    }

    private func resetShortcutStates(for actions: Set<ShortcutAction>, preservingRecording: Bool) {
        for action in actions {
            pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            interruptedRecordingActions.removeValue(forKey: action)
        }
        guard let activeRecordingShortcutAction, actions.contains(activeRecordingShortcutAction) else { return }
        heldShortcut.withLock { $0 = nil }
        let wasHoldMode = activeRecordingShortcutMode == .pushToTalk || activeRecordingShortcutMode == .hybrid
        let heldRecordingID = activeHeldRecordingID
        let currentRecordingID = activeRecordingStartID()
        let shouldFinishHeldRecording = !preservingRecording && wasHoldMode && heldRecordingID != nil
        logDecision(activeRecordingShortcutAction, phase: "reset", result: shouldFinishHeldRecording ? "finish-held-recording" : "clear-press", detail: "preservingRecording=\(preservingRecording)")
        stateRevision &+= 1
        isShortcutPressed = false
        shortcutPressStartTime = nil
        self.activeRecordingShortcutAction = nil
        activeRecordingShortcutMode = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        activeHeldRecordingID = nil
        isHandsFreeRecording = hasActiveRecording
            && (preservingRecording || !wasHoldMode || heldRecordingID != currentRecordingID)
        if shouldFinishHeldRecording, let heldRecordingID {
            finishHeldRecording(heldRecordingID)
        }
    }

    func handleShortcutDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode
    ) async {
        if isShortcutPressed, let activeAction = activeRecordingShortcutAction {
            guard !isShortcutHeld(activeAction) else {
                logDecision(action, phase: "down", result: "ignored-held-shortcut")
                return
            }
            // Recover the previous press before handling a new one.
            recoverMissedRelease(for: activeAction)
        }

        if interruptedRecordingActions.removeValue(forKey: action) == eventTime {
            logDecision(action, phase: "down", result: "ignored-interrupted")
            return
        }

        if mode == .doubleTap && (!canHandleShortcutAction() || recordingState() == .starting) {
            logDecision(action, phase: "down", result: "ignored-engine-state")
            clearPendingDoubleTap(for: action)
            return
        }

        stateRevision &+= 1
        isShortcutPressed = true
        let shortcut = canHandleShortcutAction() ? ShortcutStore.shortcut(for: action) : nil
        heldShortcut.withLock { $0 = shortcut }
        activeRecordingShortcutAction = action
        activeRecordingShortcutMode = mode
        activeShortcutIsDoubleTap = mode == .doubleTap
        activeShortcutCanCancelAccidentalStart = mode != .doubleTap && canCurrentShortcutPressCancelAccidentalStart
        shortcutPressStartTime = eventTime
        activeHeldRecordingID = nil

        switch mode {
        case .toggle:
            guard canHandleShortcutAction() else {
                logDecision(action, phase: "down", result: "ignored-engine-state", detail: "mode=toggle")
                return
            }
            if recordingState() == .idle {
                logDecision(action, phase: "down", result: "start-recording", detail: "mode=toggle")
                startRecordingForCurrentPress(action)
            } else {
                logDecision(action, phase: "down", result: "toggle-recorder", detail: "mode=toggle")
                await toggleRecording()
            }

        case .hybrid:
            guard canHandleShortcutAction() else {
                logDecision(action, phase: "down", result: "ignored-engine-state", detail: "mode=hybrid")
                return
            }
            switch recordingState() {
            case .idle:
                isHandsFreeRecording = false
                logDecision(action, phase: "down", result: "start-recording", detail: "mode=hybrid")
                startRecordingForCurrentPress(action)
            case .starting, .recording:
                let recordingID = activeRecordingStartID()
                if isHandsFreeRecording {
                    isHandsFreeRecording = false
                    logDecision(action, phase: "down", result: "stop-hands-free", detail: "mode=hybrid")
                    if let recordingID { finishHeldRecording(recordingID) }
                } else {
                    activeHeldRecordingID = recordingID
                    logDecision(action, phase: "down", result: "wait-for-release", detail: "mode=hybrid")
                }
            case .transcribing, .busy:
                break
            }

        case .pushToTalk:
            guard recordingState() == .idle, canHandleShortcutAction() else {
                logDecision(action, phase: "down", result: "ignored-engine-state", detail: "mode=pushToTalk")
                return
            }
            logDecision(action, phase: "down", result: "start-recording", detail: "mode=pushToTalk")
            startRecordingForCurrentPress(action)

        case .doubleTap:
            break
        }
    }

    private func startRecordingForCurrentPress(_ action: ShortcutAction) {
        let requestRevision = stateRevision
        let recordingID = startHeldRecording()
        if stateRevision == requestRevision, isShortcutPressed, activeRecordingShortcutAction == action {
            activeHeldRecordingID = recordingID
        } else if let recordingID {
            finishHeldRecording(recordingID)
        }
    }

    func handleShortcutUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode
    ) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            logDecision(action, phase: "up", result: "ignored-no-matching-press")
            return
        }
        guard let pressedAt = shortcutPressStartTime, eventTime >= pressedAt else { return }
        let pressDuration = eventTime - pressedAt
        let heldRecordingID = activeHeldRecordingID
        heldShortcut.withLock { $0 = nil }
        shortcutPressStartTime = nil
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeRecordingShortcutMode = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        activeHeldRecordingID = nil
        let releaseRevision = stateRevision

        switch mode {
        case .toggle:
            // Release clears the toggle shortcut's pressed state.
            isHandsFreeRecording = hasActiveRecording
            logDecision(action, phase: "up", result: "toggle-release", detail: "mode=toggle")

        case .pushToTalk:
            if let heldRecordingID {
                logDecision(action, phase: "up", result: "stop-recording", detail: "mode=pushToTalk")
                finishHeldRecording(heldRecordingID)
            } else {
                logDecision(action, phase: "up", result: "no-started-recording", detail: "mode=pushToTalk")
            }

        case .hybrid:
            if pressDuration >= hybridPressThreshold {
                isHandsFreeRecording = false
                if let heldRecordingID {
                    logDecision(action, phase: "up", result: "stop-recording", detail: "mode=hybrid duration=\(String(format: "%.3f", pressDuration))")
                    finishHeldRecording(heldRecordingID)
                } else {
                    logDecision(action, phase: "up", result: "no-started-recording", detail: "mode=hybrid")
                }
            } else {
                isHandsFreeRecording = heldRecordingID != nil
                    && heldRecordingID == activeRecordingStartID() && hasActiveRecording
                logDecision(action, phase: "up", result: isHandsFreeRecording ? "hands-free" : "no-started-recording", detail: "mode=hybrid duration=\(String(format: "%.3f", pressDuration))")
            }

        case .doubleTap:
            guard canHandleShortcutAction(), recordingState() != .starting else {
                logDecision(action, phase: "up", result: "ignored-engine-state", detail: "mode=doubleTap")
                clearPendingDoubleTap(for: action)
                break
            }
            if pressDuration < 0 || pressDuration > doubleTapThreshold {
                logDecision(action, phase: "up", result: "ignored-tap-duration", detail: "duration=\(String(format: "%.3f", pressDuration))")
                pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            } else if let firstRelease = pendingDoubleTapReleaseTimes.removeValue(forKey: action),
                eventTime - firstRelease >= 0,
                eventTime - firstRelease <= doubleTapThreshold
            {
                logDecision(action, phase: "up", result: "double-tap-triggered", detail: "interval=\(String(format: "%.3f", eventTime - firstRelease))")
                await toggleRecording()
                if stateRevision == releaseRevision {
                    isHandsFreeRecording = hasActiveRecording
                }
            } else {
                logDecision(action, phase: "up", result: "waiting-second-tap")
                pendingDoubleTapReleaseTimes[action] = eventTime
            }
        }
    }

    func handleInterruption(action: ShortcutAction, pressedAt: TimeInterval) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            if canCurrentShortcutPressCancelAccidentalStart {
                interruptedRecordingActions[action] = pressedAt
                logDecision(action, phase: "interrupted", result: "queued-before-press")
            } else {
                logDecision(action, phase: "interrupted", result: "ignored-inactive")
            }
            return
        }

        guard shortcutPressStartTime == pressedAt else { return }

        if activeShortcutIsDoubleTap {
            heldShortcut.withLock { $0 = nil }
            logDecision(action, phase: "interrupted", result: "clear-double-tap")
            stateRevision &+= 1
            isShortcutPressed = false
            shortcutPressStartTime = nil
            activeRecordingShortcutAction = nil
            activeRecordingShortcutMode = nil
            activeShortcutCanCancelAccidentalStart = false
            activeShortcutIsDoubleTap = false
            pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            return
        }

        guard activeShortcutCanCancelAccidentalStart else {
            logDecision(action, phase: "interrupted", result: "ignored-existing-recording")
            return
        }

        guard let recordingID = activeHeldRecordingID, recordingID == activeRecordingStartID() else {
            logDecision(action, phase: "interrupted", result: "ignored-recording-changed")
            reset()
            return
        }
        logDecision(action, phase: "interrupted", result: "cancel-accidental-start")
        reset()
        await cancelRecording(recordingID)
    }

    private func logDecision(_ action: ShortcutAction, phase: String, result: String, detail: String = "") {
        ShortcutDiagnostics.notice("decision action=\(action.storageName) phase=\(phase) result=\(result) state=\(recordingState()) visible=\(isRecorderVisible()) active=\(activeRecordingShortcutAction?.storageName ?? "none") \(detail)")
    }

    var diagnosticSummary: String {
        "pressed=\(isShortcutPressed) handsFree=\(isHandsFreeRecording) active=\(activeRecordingShortcutAction?.storageName ?? "none") pendingDoubleTaps=\(pendingDoubleTapReleaseTimes.keys.map(\.storageName).sorted().joined(separator: ","))"
    }

    private var hasActiveRecording: Bool {
        let state = recordingState()
        return activeRecordingStartID() != nil && (state == .starting || state == .recording)
    }

    private var canCurrentShortcutPressCancelAccidentalStart: Bool {
        recordingState() == .idle
    }
}
