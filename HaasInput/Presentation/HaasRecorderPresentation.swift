import AppKit
import Combine
import QuartzCore
import SwiftUI

enum RecorderPanelStyle: String, CaseIterable, Identifiable {
    case notch, mini
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notch: "ノッチ (画面上部)"
        case .mini: "ミニ (画面下部)"
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
    private var displayContext: HaasRecorderDisplayContext?
    private var screenSubscription: AnyCancellable?
    private var metrics: HaasRecorderSurfaceMetrics?
    private var presentationID = UUID()
    private var subscriptions = Set<AnyCancellable>()

    init(engine: HaasEngine) {
        self.engine = engine
        LifecycleObserver.shared.publisher(for: [.systemDidWake, .displaysDidWake, .screenConfigurationChanged])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isRecorderPanelVisible else { return }
                self.rebuild()
            }
            .store(in: &subscriptions)

        let layoutChanges = [
            engine.$partialTranscript.map { _ in () }.eraseToAnyPublisher(),
            engine.$errorMessage.map { _ in () }.eraseToAnyPublisher(),
            engine.$hasUnsavedHistory.map { _ in () }.eraseToAnyPublisher(),
            engine.inputDelivery.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(layoutChanges)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLayout() }
            .store(in: &subscriptions)
    }

    func recordingStateDidChange(_ state: RecordingState) {
        switch state {
        case .starting:
            presentationID = UUID()
            rebuild()
        case .recording, .transcribing, .busy:
            if panel == nil { rebuild() }
            else { refreshLayout() }
        case .idle:
            if viewState.mode == .attention {
                if panel == nil { rebuild() }
                else { refreshLayout() }
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
        screenSubscription = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        displayContext = nil
        metrics = nil
        isRecorderPanelVisible = false
    }

    private var viewState: HaasRecorderViewState {
        HaasRecorderViewState(
            recordingState: engine.recordingState,
            duration: engine.recordedDuration,
            transcript: engine.partialTranscript,
            showsTranscript: UserDefaults.standard.object(forKey: RecorderDisplaySettingsKeys.showLiveTranscript) as? Bool ?? true,
            errorMessage: engine.errorMessage,
            hasUnsavedHistory: engine.hasUnsavedHistory,
            recovery: HaasPendingInputState(delivery: engine.inputDelivery,
                canResume: engine.recordingState == .idle || engine.recordingState == .recording)
        )
    }

    private func rebuild() {
        screenSubscription = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        guard let screen = RecorderScreenResolver.resolve() else {
            isRecorderPanelVisible = false
            return
        }
        let placement = HaasRecorderPlacement(screen: screen)
        let displayContext = HaasRecorderDisplayContext(placement: placement)
        let metrics = placement.metrics(state: viewState, style: recorderPanelStyle)
        let panel = HaasRecorderPanel(contentRect: placement.frame(metrics: metrics, style: recorderPanelStyle), style: recorderPanelStyle)
        let content = HaasRecorderPanelView(
            engine: engine, style: recorderPanelStyle, displayContext: displayContext,
            onClose: { [weak self] in self?.close() }
        )
        panel.contentView = NSHostingView(rootView: content)
        self.panel = panel
        self.displayContext = displayContext
        self.metrics = metrics
        screenSubscription = NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification, object: panel)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak panel] _ in
                guard let self, self.panel === panel else { return }
                self.refreshLayout()
            }
        panel.orderFrontRegardless()
        isRecorderPanelVisible = true
    }

    private func refreshLayout() {
        guard isRecorderPanelVisible, let panel, let displayContext else { return }
        var placement = displayContext.placement
        if recorderPanelStyle == .mini, let screen = panel.screen {
            placement = HaasRecorderPlacement(screen: screen)
        }
        let displayChanged = placement != displayContext.placement
        if displayChanged { displayContext.placement = placement }
        let state = viewState
        if state.recordingState == .idle, state.mode != .attention {
            hide()
            return
        }
        let next = placement.metrics(state: state, style: recorderPanelStyle)
        guard next != metrics else { return }
        metrics = next
        let frame = placement.frame(metrics: next, style: recorderPanelStyle,
                                    preservingMiniOrigin: recorderPanelStyle == .mini ? panel.frame : nil)
        if displayChanged || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        }
    }
}

@MainActor
private final class HaasRecorderDisplayContext: ObservableObject {
    @Published var placement: HaasRecorderPlacement

    init(placement: HaasRecorderPlacement) {
        self.placement = placement
    }
}

private struct HaasRecorderPlacement: Equatable {
    let screenFrame: CGRect
    let visibleFrame: CGRect
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let hasPhysicalNotch: Bool

    @MainActor init(screen: NSScreen) {
        screenFrame = screen.frame
        visibleFrame = screen.visibleFrame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(0, screen.frame.width - left.width - right.width)
            notchHeight = screen.safeAreaInsets.top
            hasPhysicalNotch = true
        } else {
            notchWidth = 120
            notchHeight = max(24, NSStatusBar.system.thickness)
            hasPhysicalNotch = false
        }
    }

    func metrics(state: HaasRecorderViewState, style: RecorderPanelStyle) -> HaasRecorderSurfaceMetrics {
        HaasRecorderSurfaceMetrics(state: state, style: style, notchWidth: notchWidth,
                                   notchHeight: notchHeight, maximumWidth: screenFrame.width - 24)
    }

    func frame(metrics: HaasRecorderSurfaceMetrics, style: RecorderPanelStyle, preservingMiniOrigin old: CGRect? = nil) -> CGRect {
        let size = CGSize(width: metrics.width + 16, height: metrics.height + (style == .mini ? 16 : 10))
        if style == .notch {
            return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
                          width: size.width, height: size.height)
        }
        let center = old?.midX ?? visibleFrame.midX
        let x = min(max(visibleFrame.minX + 8, center - size.width / 2), visibleFrame.maxX - size.width - 8)
        let y = min(max(visibleFrame.minY + 8, old?.minY ?? visibleFrame.minY + 18), visibleFrame.maxY - size.height - 8)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

private final class HaasRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, style: RecorderPanelStyle) {
        let mask: NSWindow.StyleMask = style == .notch
            ? [.borderless, .nonactivatingPanel, .fullSizeContentView]
            : [.borderless, .nonactivatingPanel]
        super.init(contentRect: contentRect, styleMask: mask, backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        level = style == .mini ? .floating : NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = style == .mini
        isMovableByWindowBackground = style == .mini
        appearance = NSAppearance(named: .darkAqua)
    }
}

@MainActor
private struct HaasRecorderPanelView: View {
    @ObservedObject var engine: HaasEngine
    @ObservedObject private var delivery: HaasInputDelivery
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    let style: RecorderPanelStyle
    @ObservedObject private var displayContext: HaasRecorderDisplayContext
    let onClose: () -> Void

    private var placement: HaasRecorderPlacement { displayContext.placement }

    init(engine: HaasEngine, style: RecorderPanelStyle, displayContext: HaasRecorderDisplayContext, onClose: @escaping () -> Void) {
        self.engine = engine
        _delivery = ObservedObject(wrappedValue: engine.inputDelivery)
        self.style = style
        _displayContext = ObservedObject(wrappedValue: displayContext)
        self.onClose = onClose
    }

    var body: some View {
        HaasRecorderSurface(
            state: HaasRecorderViewState(
                recordingState: engine.recordingState, duration: engine.recordedDuration,
                transcript: engine.partialTranscript, showsTranscript: showLiveTranscript,
                errorMessage: engine.errorMessage, hasUnsavedHistory: engine.hasUnsavedHistory,
                recovery: HaasPendingInputState(delivery: delivery,
                    canResume: engine.recordingState == .idle || engine.recordingState == .recording)
            ),
            style: style, notchWidth: placement.notchWidth, notchHeight: placement.notchHeight,
            hasPhysicalNotch: placement.hasPhysicalNotch, maximumWidth: placement.screenFrame.width - 24,
            audioMeterProvider: engine.recorder.audioMeterSnapshot,
            actions: HaasRecorderActions(
                close: onClose,
                stop: { Task { await engine.toggleRecording() } },
                retryHistory: engine.retrySavingHistory,
                copyTranscript: engine.copyLastTranscription,
                recovery: HaasPendingInputActions(
                    acknowledge: delivery.acknowledgeUncertainInput,
                    copy: { delivery.copyPending() },
                    scheduleResume: delivery.scheduleResume,
                    cancelResume: delivery.cancelScheduledResume
                )
            )
        )
        .padding(.horizontal, 8)
        .padding(.top, style == .mini ? 8 : 0)
        .padding(.bottom, style == .mini ? 8 : 10)
        .ignoresSafeArea(.container, edges: style == .notch ? .top : [])
    }
}
