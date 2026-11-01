import AppKit
import Combine
import SwiftUI

enum RecorderPanelStyle: String, CaseIterable, Identifiable {
    case notch, mini
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notch: "画面上部"
        case .mini: "小さなパネル"
        }
    }

    static var stored: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "RecorderType") ?? "") ?? .mini
    }
}

@MainActor
final class HaasRecorderPresentation: ObservableObject {
    @Published private(set) var isRecorderPanelVisible = false
    @Published var recorderPanelStyle: RecorderPanelStyle = .stored {
        didSet {
            guard recorderPanelStyle != oldValue else { return }
            UserDefaults.standard.set(recorderPanelStyle.rawValue, forKey: "RecorderType")
            if isRecorderPanelVisible { rebuild() }
        }
    }

    private let engine: HaasEngine
    private var panel: HaasRecorderPanel?
    private var presentationID = UUID()
    private var lifecycleSubscription: AnyCancellable?

    init(engine: HaasEngine) {
        self.engine = engine
        lifecycleSubscription = LifecycleObserver.shared.publisher(
            for: [.systemDidWake, .displaysDidWake, .screenConfigurationChanged]
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self, self.isRecorderPanelVisible else { return }
            self.rebuild()
        }
    }

    func recordingStateDidChange(_ state: RecordingState) {
        switch state {
        case .starting:
            presentationID = UUID()
            rebuild()
        case .recording, .transcribing, .busy:
            if panel == nil { rebuild() }
        case .idle:
            if engine.inputDelivery.hasRecovery || engine.hasUnsavedHistory || engine.errorMessage != nil {
                if panel == nil { rebuild() }
            } else {
                hide()
            }
        }
    }

    func close() {
        let expectedID = presentationID
        engine.inputDelivery.pauseForPanelDismissal()
        if engine.recordingState == .idle {
            hide()
        } else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.engine.cancelRecording()
                guard self.presentationID == expectedID else { return }
                self.hide()
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        isRecorderPanelVisible = false
    }

    private func rebuild() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        guard let screen = RecorderScreenResolver.resolve() else {
            isRecorderPanelVisible = false
            return
        }
        let size = NSSize(width: 440, height: 380)
        let area = screen.visibleFrame
        let y = recorderPanelStyle == .mini ? area.minY + 18 : area.maxY - size.height - 8
        let rect = NSRect(x: area.midX - size.width / 2, y: y, width: size.width, height: size.height)
        let panel = HaasRecorderPanel(contentRect: rect)
        panel.level = recorderPanelStyle == .mini ? .floating : .statusBar
        let content = HaasRecorderPanelView(engine: engine, onClose: { [weak self] in self?.close() })
            .frame(width: size.width, height: size.height, alignment: recorderPanelStyle == .mini ? .bottom : .top)
        panel.contentView = NSHostingView(rootView: content)
        panel.orderFrontRegardless()
        self.panel = panel
        isRecorderPanelVisible = true
    }
}

private final class HaasRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        appearance = NSAppearance(named: .darkAqua)
    }
}

@MainActor
private struct HaasRecorderPanelView: View {
    @ObservedObject var engine: HaasEngine
    @ObservedObject private var delivery: HaasInputDelivery
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    let onClose: () -> Void

    init(engine: HaasEngine, onClose: @escaping () -> Void) {
        self.engine = engine
        _delivery = ObservedObject(wrappedValue: engine.inputDelivery)
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if engine.recordingState == .recording {
                    Circle().fill(.red).frame(width: 8, height: 8)
                } else if engine.recordingState != .idle {
                    ProgressView().controlSize(.small)
                }
                Text(engine.recordingState.displayName).font(.headline)
                Spacer()
                Text(durationText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help(engine.recordingState == .idle ? "パネルを閉じる" : "録音を取り消して閉じる")
                    .accessibilityLabel(engine.recordingState == .idle ? "パネルを閉じる" : "録音を取り消して閉じる")
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            if engine.recordingState == .recording {
                HaasAudioMeterView(engine: engine)
            }
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if showLiveTranscript, !engine.partialTranscript.isEmpty {
                            Text(verbatim: engine.partialTranscript)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("latest")
                        } else if engine.recordingState == .recording {
                            Text("話した内容を認識しています…")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let error = engine.errorMessage {
                            Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if engine.hasUnsavedHistory {
                            HStack {
                                Button("保存を再試行") { engine.retrySavingHistory() }
                                Button("文章をコピー") { engine.copyLastTranscription() }
                            }
                        }
                        if delivery.hasRecovery {
                            HaasPendingInputView(
                                delivery: delivery,
                                canResume: engine.recordingState == .idle || engine.recordingState == .recording
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .onChange(of: engine.partialTranscript) { _, _ in
                    guard !delivery.hasRecovery, engine.errorMessage == nil, !engine.hasUnsavedHistory else { return }
                    reader.scrollTo("latest", anchor: .bottom)
                }
            }
            if engine.recordingState == .recording {
                HStack {
                    Button("取り消す") { Task { await engine.cancelRecording() } }
                    Spacer()
                    Button("録音を終了") { Task { await engine.toggleRecording() } }
                        .buttonStyle(.borderedProminent)
                }
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)) }
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "ja_JP"))
        .padding(6)
    }

    private var durationText: String {
        let seconds = max(0, Int(engine.recordedDuration))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

@MainActor
private struct HaasAudioMeterView: View {
    let engine: HaasEngine

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            let level = max(0, min(1, engine.recorder.audioMeterSnapshot().averagePower))
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<18) { index in
                    let wave = 0.45 + 0.55 * abs(sin(context.date.timeIntervalSinceReferenceDate * 8 + Double(index) * 0.45))
                    Capsule().fill(.mint)
                        .frame(width: 3, height: max(3, 24 * CGFloat(Double(level) * wave)))
                }
                Spacer()
            }
            .frame(height: 26)
        }
        .accessibilityHidden(true)
    }
}
