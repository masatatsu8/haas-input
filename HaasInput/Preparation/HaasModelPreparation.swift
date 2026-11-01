import Combine
import Foundation
import os

@MainActor
final class HaasModelPreparation: ObservableObject {
    enum State {
        case idle
        case preparing
        case ready
        case cancelled
        case failed(String)
    }

    static let shared = HaasModelPreparation(settings: .shared, assets: .shared)

    @Published private(set) var state: State = .idle
    @Published private(set) var progress: HaasModelPreparationProgress?
    @Published private(set) var isWorking = false
    @Published private(set) var hasCustomPaths = false

    private let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "HaasModelPreparation")
    private let settings: HaasSettingsStore
    private let assets: HaasModelAssets
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var cancellationRequested = false
    private var didStartAtLaunch = false
    private var refreshAfterCancellation = false
    private var lastSelection: HaasRuntimeSelection?

    init(settings: HaasSettingsStore, assets: HaasModelAssets) {
        self.settings = settings
        self.assets = assets
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    func startAtLaunchIfNeeded() {
        guard !didStartAtLaunch else { return }
        didStartAtLaunch = true
        prepare()
    }

    func prepare() {
        begin(downloadMissing: true)
    }

    func verify() {
        begin(downloadMissing: false)
    }

    func refreshIfNeeded() {
        guard task == nil else { return }
        switch state {
        case .idle:
            verify()
        case .ready:
            let selection = settings.runtimeSelection
            remember(selection)
            do {
                _ = try assets.resolvedConfiguration(for: selection)
            } catch {
                progress = nil
                logger.error("Model preparation failed: \(String(describing: error), privacy: .private)")
                state = .failed(HaasErrorPresentation.message(for: error, fallback: "音声認識モデルを準備できませんでした。設定を確認して再試行してください。"))
            }
        case .preparing, .cancelled, .failed:
            break
        }
    }

    func cancel() {
        guard task != nil else { return }
        refreshAfterCancellation = false
        cancellationRequested = true
        state = .cancelled
        task?.cancel()
    }

    func configurationDidChange() {
        let selection = settings.runtimeSelection
        guard selection != lastSelection else { return }
        remember(selection)
        if task != nil {
            cancel()
            refreshAfterCancellation = true
        } else {
            verify()
        }
    }

    func useAutomaticConfiguration() {
        guard task == nil else { return }
        settings.executablePath = ""
        settings.modelPath = ""
        settings.vadModelPath = ""
        prepare()
    }

    private func remember(_ selection: HaasRuntimeSelection) {
        lastSelection = selection
        hasCustomPaths = [selection.executablePath, selection.modelPath, selection.vadModelPath].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func begin(downloadMissing: Bool) {
        guard task == nil else { return }
        let selection = settings.runtimeSelection
        remember(selection)
        let id = UUID()
        operationID = id
        cancellationRequested = false
        state = .preparing
        progress = nil
        isWorking = true

        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if operationID == id {
                    task = nil
                    operationID = nil
                    isWorking = false
                    if refreshAfterCancellation {
                        refreshAfterCancellation = false
                        verify()
                    }
                }
            }
            do {
                _ = try await assets.prepare(
                    selection,
                    downloadMissing: downloadMissing
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrent(id, selection: selection) else { return }
                        self.progress = progress
                    }
                }
                guard isCurrent(id, selection: selection) else { return }
                state = .ready
            } catch is CancellationError {
                if operationID == id { state = .cancelled }
            } catch {
                guard isCurrent(id, selection: selection) else { return }
                logger.error("Model preparation failed: \(String(describing: error), privacy: .private)")
                state = .failed(HaasErrorPresentation.message(for: error, fallback: "音声認識モデルを準備できませんでした。設定を確認して再試行してください。"))
            }
        }
    }

    private func isCurrent(_ id: UUID, selection: HaasRuntimeSelection) -> Bool {
        operationID == id && !cancellationRequested
            && selection == settings.runtimeSelection
    }
}
