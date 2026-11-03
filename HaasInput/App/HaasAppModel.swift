import AppKit
import Combine
import Foundation
import OSLog
import SwiftData

@MainActor
final class HaasAppModel: ObservableObject {
    @Published var selectedDestination: HaasDestination = .home
    @Published var selectedHistoryID: UUID?
    @Published var selectedSettingsTab: HaasSettingsTab = .general
    @Published private(set) var startupError: String?

    let permissions = HaasPermissions()
    private(set) var persistence: HaasPersistence?
    private(set) var engine: HaasEngine?
    private(set) var presentation: HaasRecorderPresentation?
    private(set) var shortcuts: RecordingShortcutManager?
    var openMainWindow: (() -> Void)?

    private var subscriptions = Set<AnyCancellable>()
    private var previousRecordingState: RecordingState = .idle
    private let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "Application")

    init() {
        do {
            let persistence = try HaasPersistence()
            self.persistence = persistence
            let engine = HaasEngine(modelContext: persistence.mainContext)
            self.engine = engine
            let presentation = HaasRecorderPresentation(engine: engine)
            self.presentation = presentation
            let shortcuts = RecordingShortcutManager(
                recordingState: { [weak engine] in engine?.recordingState ?? .idle },
                isRecorderVisible: { [weak presentation] in presentation?.isRecorderPanelVisible ?? false },
                activeRecordingStartID: { [weak engine] in engine?.activeRecordingStartID },
                startHeldRecording: { [weak engine] in engine?.startHeldRecording() },
                finishHeldRecording: { [weak engine] id in engine?.finishHeldShortcutRecording(recordingID: id) },
                cancelHeldRecording: { [weak engine] id in await engine?.cancelRecording(recordingID: id) },
                toggleRecording: { [weak engine] in await engine?.toggleRecording() },
                cancelRecording: { [weak engine] in await engine?.cancelRecording() },
                pasteLastTranscription: { [weak engine] in engine?.pasteLastTranscription() },
                openHistory: { [weak self] in self?.show(.history) }
            )
            self.shortcuts = shortcuts

            engine.$recordingState
                .receive(on: RunLoop.main)
                .sink { [weak self] state in
                    guard let self else { return }
                    self.presentation?.recordingStateDidChange(state)
                    self.shortcuts?.updateRecorderState()
                    if state == .recording, self.previousRecordingState != .recording {
                        SoundManager.shared.playStartSound()
                    } else if self.previousRecordingState == .recording, state == .transcribing {
                        SoundManager.shared.playStopSound()
                    } else if state == .busy, self.previousRecordingState == .recording || self.previousRecordingState == .starting {
                        SoundManager.shared.playEscSound()
                    }
                    self.previousRecordingState = state
                }
                .store(in: &subscriptions)
            presentation.$isRecorderPanelVisible
                .receive(on: RunLoop.main)
                .sink { [weak shortcuts] _ in shortcuts?.updateRecorderState() }
                .store(in: &subscriptions)
            NotificationCenter.default.publisher(for: .showAudioSettingsRequested)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.selectedSettingsTab = .audio
                    self?.show(.settings)
                }
                .store(in: &subscriptions)

            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
                .receive(on: RunLoop.main)
                .sink { _ in HaasPasteTarget.prepareForegroundAccessibility() }
                .store(in: &subscriptions)
            HaasPasteTarget.prepareForegroundAccessibility()

            ShortcutDiagnostics.setRecordingContext { [weak engine] in
                "state=\(engine?.recordingState.rawValue ?? "unavailable")"
            }
            HaasModelPreparation.shared.startAtLaunchIfNeeded()
        } catch {
            logger.error("Persistent storage startup failed: \(String(describing: error), privacy: .private)")
            startupError = "保存済みの履歴や辞書を開けませんでした。元のデータは保持しています。保存先とアクセス権を確認してから、アプリを起動し直してください。"
        }
    }

    func show(_ destination: HaasDestination) {
        selectedDestination = destination
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func showAbout() {
        selectedSettingsTab = .about
        show(.settings)
    }

    func refreshPermissions() {
        let previouslyGranted = permissions.accessibilityGranted
        permissions.refresh()
        if !previouslyGranted, permissions.accessibilityGranted {
            shortcuts?.updateShortcutStatus()
        }
    }

}
