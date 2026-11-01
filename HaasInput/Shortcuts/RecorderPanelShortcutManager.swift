import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class RecorderPanelShortcutManager {
    private let isRecorderVisible: @MainActor () -> Bool
    private let cancelRecording: @MainActor () async -> Void
    private let visibleRecorderMonitor: ShortcutMonitor
    private var shortcutChangeObserver: NSObjectProtocol?
    private var firstEscapePressTime: Date?
    private var escapeTimeoutTask: Task<Void, Never>?
    private var activeEscapePressID: UUID?
    private var isEscapeConfirmationHintVisible = false
    private let escapeDoublePressThreshold: TimeInterval = 1.5
    private static let escapeConfirmationHintShownKey = "hasShownEscapeCancelConfirmationHint"

    static func resetEscapeConfirmationHint() {
        UserDefaults.standard.removeObject(forKey: escapeConfirmationHintShownKey)
    }

    init(
        isRecorderVisible: @escaping @MainActor () -> Bool,
        cancelRecording: @escaping @MainActor () async -> Void,
        heldRecordingShortcut: @escaping @Sendable () -> Shortcut?
    ) {
        self.isRecorderVisible = isRecorderVisible
        self.cancelRecording = cancelRecording
        visibleRecorderMonitor = ShortcutMonitor(owner: "recorder-panel", heldRecordingShortcut: heldRecordingShortcut)
        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let action = notification.object as? ShortcutAction else { return }
            Task { @MainActor in
                if action == .cancelRecorder { self?.resetEscapeState() }
                self?.refresh(reason: "store-change.\(action.storageName)")
            }
        }
    }

    func refresh(reason: String) {
        guard isRecorderVisible() else {
            stop()
            return
        }
        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.recorderPanelStoredActions)
        if ShortcutStore.shortcut(for: .cancelRecorder) == nil {
            shortcuts[.recorderPanelEscape] = .key(keyCode: UInt16(kVK_Escape), modifierFlags: [])
        }
        let reservedActions = [ShortcutAction.primaryRecording, .secondaryRecording] + ShortcutAction.globalUtilityActions
        visibleRecorderMonitor.start(
            shortcuts: shortcuts,
            reservedShortcuts: Array(ShortcutStore.shortcuts(for: reservedActions).values),
            onShortcutDown: { [weak self] action, _ in await self?.handleShortcut(action) },
            onShortcutUp: { _, _ in },
            reason: reason
        )
    }

    func stop() {
        visibleRecorderMonitor.stop(reason: "panel-hidden")
        resetEscapeState()
    }

    private func handleShortcut(_ action: ShortcutAction) async {
        guard isRecorderVisible() else { return }
        switch action {
        case .cancelRecorder:
            guard ShortcutStore.shortcut(for: .cancelRecorder) != nil else { return }
            await cancelRecording()
        case .recorderPanelEscape:
            await handleEscapeShortcut()
        default:
            break
        }
    }

    private func handleEscapeShortcut() async {
        guard ShortcutStore.shortcut(for: .cancelRecorder) == nil else { return }
        let now = Date()
        if let firstTime = firstEscapePressTime,
            now.timeIntervalSince(firstTime) <= escapeDoublePressThreshold
        {
            ShortcutDiagnostics.notice("panel action=recorderPanelEscape result=cancel-confirmed")
            resetEscapeState()
            await cancelRecording()
            return
        }
        ShortcutDiagnostics.notice("panel action=recorderPanelEscape result=waiting-confirmation")
        let pressID = UUID()
        firstEscapePressTime = now
        activeEscapePressID = pressID
        showEscapeConfirmationHintIfNeeded()
        escapeTimeoutTask?.cancel()
        escapeTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.escapeDoublePressThreshold ?? 1.5))
            } catch { return }
            guard let self, activeEscapePressID == pressID else { return }
            firstEscapePressTime = nil
            activeEscapePressID = nil
            escapeTimeoutTask = nil
            isEscapeConfirmationHintVisible = false
        }
    }

    private func resetEscapeState() {
        firstEscapePressTime = nil
        activeEscapePressID = nil
        escapeTimeoutTask?.cancel()
        escapeTimeoutTask = nil
        if isEscapeConfirmationHintVisible {
            isEscapeConfirmationHintVisible = false
            NotificationManager.shared.dismissNotification()
        }
    }

    private func showEscapeConfirmationHintIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.escapeConfirmationHintShownKey) else { return }
        defaults.set(true, forKey: Self.escapeConfirmationHintShownKey)
        isEscapeConfirmationHintVisible = true
        NotificationManager.shared.showNotification(
            title: "もう一度Escを押すと録音を取り消します。", type: .info, duration: escapeDoublePressThreshold
        )
    }

    isolated deinit {
        if let shortcutChangeObserver { NotificationCenter.default.removeObserver(shortcutChangeObserver) }
        stop()
    }
}
