import SwiftUI

struct HaasRecorderViewState {
    var recordingState: RecordingState = .idle
    var duration: TimeInterval = 0
    var transcript = ""
    var showsTranscript = true
    var errorMessage: String?
    var hasUnsavedHistory = false
    var recovery = HaasPendingInputState()

    var mode: HaasRecorderSurfaceMode {
        if recovery.isVisible || errorMessage != nil || hasUnsavedHistory { return .attention }
        if showsTranscript, !transcript.isEmpty, recordingState != .idle { return .transcript }
        return .compact
    }

    var title: String {
        if recovery.isVisible { return recovery.title }
        if hasUnsavedHistory { return "履歴を保存できません" }
        if errorMessage != nil { return "確認が必要です" }
        switch recordingState {
        case .idle: return "完了"
        case .starting: return "準備中"
        case .recording: return "録音中"
        case .transcribing: return "認識中"
        case .busy: return "終了中"
        }
    }
}

enum HaasRecorderSurfaceMode: Equatable {
    case compact, transcript, attention
}

struct HaasRecorderActions {
    let close: () -> Void
    let stop: () -> Void
    let retryHistory: () -> Void
    let copyTranscript: () -> Void
    let recovery: HaasPendingInputActions
}

enum HaasRecorderTheme {
    static let background = Color.black
    static let materialTint = Color.black.opacity(0.92)
    static let text = Color.white.opacity(0.95)
    static let muted = Color.white.opacity(0.68)
    static let divider = Color.white.opacity(0.12)
    static let control = Color.white.opacity(0.10)
    static let hover = Color.white.opacity(0.18)
    static let accent = Color(red: 244.0 / 255.0, green: 189.0 / 255.0, blue: 166.0 / 255.0)
    static let accentInk = Color(red: 34.0 / 255.0, green: 23.0 / 255.0, blue: 19.0 / 255.0)
    static let warning = Color(red: 1, green: 0.78, blue: 0.40)
    static let shadow = Color.black.opacity(0.28)
}

struct HaasRecorderSurfaceMetrics: Equatable {
    let width: CGFloat
    let controlHeight: CGFloat
    let bodyHeight: CGFloat
    let notchGapWidth: CGFloat
    var height: CGFloat { controlHeight + bodyHeight + (bodyHeight > 0 ? 0.5 : 0) }

    init(state: HaasRecorderViewState, style: RecorderPanelStyle, notchWidth: CGFloat, notchHeight: CGFloat, maximumWidth: CGFloat) {
        let desiredWidth: CGFloat
        switch (style, state.mode) {
        case (.mini, .compact): desiredWidth = 232
        case (.mini, .transcript): desiredWidth = 340
        case (.mini, .attention): desiredWidth = 420
        case (.notch, .compact): desiredWidth = max(320, notchWidth + 208)
        case (.notch, .transcript): desiredWidth = max(392, notchWidth + 208)
        case (.notch, .attention): desiredWidth = max(440, notchWidth + 208)
        }
        width = min(desiredWidth, max(232, maximumWidth))
        controlHeight = style == .mini ? 52 : max(44, notchHeight + 8)
        notchGapWidth = min(notchWidth, max(0, width - 208))
        switch state.mode {
        case .compact:
            bodyHeight = 0
        case .transcript:
            bodyHeight = 76
        case .attention:
            let pendingRows = state.recovery.pendingText.isEmpty ? 0 : (width < 340 ? 2 : 1)
            let uncertainRows = state.recovery.uncertainText.isEmpty ? 0 : 1
            let historyRows = state.hasUnsavedHistory ? 1 : 0
            bodyHeight = min(320, 176 + CGFloat(pendingRows + uncertainRows + historyRows) * 32)
        }
    }
}

@MainActor
struct HaasRecorderSurface: View {
    let state: HaasRecorderViewState
    let style: RecorderPanelStyle
    var notchWidth: CGFloat = 180
    var notchHeight: CGFloat = 32
    var hasPhysicalNotch = false
    var maximumWidth: CGFloat = 800
    let audioMeterProvider: () -> AudioMeter
    let actions: HaasRecorderActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var metrics: HaasRecorderSurfaceMetrics {
        HaasRecorderSurfaceMetrics(state: state, style: style, notchWidth: notchWidth, notchHeight: notchHeight, maximumWidth: maximumWidth)
    }

    var body: some View {
        Group {
            if style == .mini {
                VStack(spacing: 0) {
                    if state.mode != .compact {
                        detail
                        separator
                    }
                    miniControls
                }
                .frame(width: metrics.width, height: metrics.height)
                .background {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        HaasRecorderTheme.materialTint
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(HaasRecorderTheme.divider, lineWidth: 0.6) }
                .shadow(color: HaasRecorderTheme.shadow, radius: 8, y: 3)
            } else {
                VStack(spacing: 0) {
                    notchControls
                    if state.mode != .compact {
                        separator
                        detail
                    }
                }
                .frame(width: metrics.width, height: metrics.height)
                .background(HaasRecorderTheme.background)
                .clipShape(HaasRecorderNotchShape(topCornerRadius: 9, bottomCornerRadius: state.mode == .compact ? 16 : 22))
                .overlay {
                    HaasRecorderNotchShape(topCornerRadius: 9, bottomCornerRadius: state.mode == .compact ? 16 : 22)
                        .stroke(HaasRecorderTheme.divider, lineWidth: 0.6)
                        .allowsHitTesting(false)
                }
                .shadow(color: HaasRecorderTheme.shadow, radius: 7, y: 3)
            }
        }
        .foregroundStyle(HaasRecorderTheme.text)
        .tint(HaasRecorderTheme.accent)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "ja_JP"))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: state.mode)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(style == .mini ? "haasMiniRecorder" : "haasNotchRecorder")
    }

    private var cornerRadius: CGFloat { state.mode == .compact ? 26 : 19 }
    private var separator: some View { HaasRecorderTheme.divider.frame(height: 0.5).padding(.horizontal, 14) }

    private var miniControls: some View {
        HStack(spacing: 6) {
            closeButton
            if state.mode == .attention {
                Label(state.title, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HaasRecorderTheme.warning)
                    .lineLimit(1)
                Spacer(minLength: 4)
                duration
            } else {
                Spacer(minLength: 0)
                activity
                duration
                Spacer(minLength: 0)
            }
            stopControl
        }
        .padding(.horizontal, 6)
        .frame(height: metrics.controlHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var notchControls: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) { closeButton; stopControl }
                .frame(maxWidth: .infinity)
            Group {
                if hasPhysicalNotch { Color.clear }
                else {
                    Text(state.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(state.mode == .attention ? HaasRecorderTheme.warning : HaasRecorderTheme.muted)
                        .lineLimit(1)
                }
            }
            .frame(width: metrics.notchGapWidth)
            HStack(spacing: 6) {
                if state.recordingState == .recording {
                    HaasRecorderWaveform(audioMeterProvider: audioMeterProvider)
                } else {
                    let symbol = state.mode == .attention ? "exclamationmark.circle.fill"
                        : (state.recordingState == .idle ? "checkmark" : "ellipsis")
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(state.mode == .attention ? HaasRecorderTheme.warning : HaasRecorderTheme.muted)
                        .frame(width: 48, height: 22)
                        .accessibilityHidden(true)
                }
                duration
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .frame(height: metrics.controlHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var closeButton: some View {
        HaasRecorderIconButton(
            symbol: "xmark",
            label: state.recordingState == .idle ? "パネルを閉じる" : "録音を取り消して閉じる",
            prominent: false,
            action: actions.close
        )
        .accessibilityIdentifier("haasRecorderClose")
    }

    @ViewBuilder
    private var stopControl: some View {
        if state.recordingState == .recording {
            HaasRecorderIconButton(symbol: "stop.fill", label: "録音を終了", prominent: true, action: actions.stop)
                .accessibilityIdentifier("haasRecorderStop")
        } else if state.recordingState == .idle {
            Image(systemName: state.mode == .attention ? "pause.fill" : "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(state.mode == .attention ? HaasRecorderTheme.warning : HaasRecorderTheme.accent)
                .frame(width: 44, height: 44)
                .accessibilityLabel(state.title)
        } else {
            ProgressView().controlSize(.small).tint(HaasRecorderTheme.accent)
                .frame(width: 44, height: 44)
                .accessibilityLabel(state.title)
        }
    }

    @ViewBuilder
    private var activity: some View {
        if state.recordingState == .recording {
            HaasRecorderWaveform(audioMeterProvider: audioMeterProvider)
        } else {
            Text(state.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HaasRecorderTheme.muted)
                .lineLimit(1)
                .frame(minWidth: 42)
        }
    }

    private var duration: some View {
        let seconds = state.duration.isFinite ? max(0, Int(min(state.duration, 35_999_999))) : 0
        return Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(HaasRecorderTheme.muted)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(width: 42)
            .accessibilityLabel("録音時間 \(seconds / 60)分\(seconds % 60)秒")
    }

    @ViewBuilder
    private var detail: some View {
        if state.mode == .transcript {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Text(verbatim: state.transcript)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    Color.clear.frame(height: 1).id("latest")
                }
                .scrollIndicators(.hidden)
                .onChange(of: state.transcript) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
                .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
                .transaction { $0.animation = nil }
            }
            .frame(height: metrics.bodyHeight)
        } else {
            attentionDetail.frame(height: metrics.bodyHeight)
        }
    }

    private var attentionDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label(state.title, systemImage: "exclamationmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HaasRecorderTheme.warning)
                    if let error = state.errorMessage,
                        error != state.recovery.errorMessage, error != state.recovery.statusMessage {
                        Text(error).font(.caption).textSelection(.enabled)
                    }
                    if state.recovery.isVisible {
                        HaasPendingInputBody(state: state.recovery)
                    } else if state.showsTranscript, !state.transcript.isEmpty {
                        Text(verbatim: state.transcript)
                            .font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if state.hasUnsavedHistory {
                HStack(spacing: 8) {
                    Button("保存を再試行", action: actions.retryHistory)
                    Button("文章をコピー", action: actions.copyTranscript)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            if state.recovery.isVisible {
                HaasPendingInputControls(state: state.recovery, actions: actions.recovery)
            }
        }
        .padding(16)
    }
}

@MainActor
private struct HaasRecorderIconButton: View {
    let symbol: String
    let label: String
    let prominent: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 11 : 10, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(prominent ? HaasRecorderTheme.accent : (hovering ? HaasRecorderTheme.hover : HaasRecorderTheme.control)))
                .foregroundStyle(prominent ? HaasRecorderTheme.accentInk : HaasRecorderTheme.text)
                .overlay { Circle().strokeBorder(focused ? HaasRecorderTheme.text : Color.clear, lineWidth: 2).padding(-3) }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(HaasRecorderPressStyle())
        .focused($focused)
        .onHover { hovering = $0 }
        .opacity(enabled ? 1 : 0.45)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct HaasRecorderPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

@MainActor
private struct HaasRecorderWaveform: View {
    let audioMeterProvider: () -> AudioMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : 0.06)) { context in
            let meter = audioMeterProvider()
            let level = meter.averagePower.isFinite ? max(0, min(1, meter.averagePower)) : 0
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<9) { index in
                    let phase = Double(index) * 0.6
                    let rhythm = reduceMotion ? 0.8 : 0.45 + 0.55 * abs(sin(context.date.timeIntervalSinceReferenceDate * 8 + phase))
                    Capsule().fill(HaasRecorderTheme.accent)
                        .frame(width: 2.5, height: max(3, 20 * CGFloat(level * rhythm)))
                }
            }
            .frame(width: 48, height: 22)
        }
        .accessibilityHidden(true)
    }
}

struct HaasRecorderNotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
                          control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
                          control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
                          control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
