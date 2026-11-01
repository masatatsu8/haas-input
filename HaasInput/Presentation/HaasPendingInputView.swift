import SwiftUI

struct HaasPendingInputState: Equatable {
    var isVisible = false
    var statusMessage = ""
    var errorMessage: String?
    var pendingText = ""
    var uncertainText = ""
    var isPaused = true
    var hasUnreadableRecovery = false
    var hasUnsavedRecovery = false
    var resumeCountdown: Int?
    var canResume = true

    var title: String {
        if hasUnreadableRecovery { return "確認待ちを読み込めません" }
        if hasUnsavedRecovery { return "確認待ちの保存に問題があります" }
        if pendingText.isEmpty, !uncertainText.isEmpty { return "入力済みか確認してください" }
        return "入力を保留中"
    }

    var canAcknowledge: Bool { isPaused && !hasUnreadableRecovery }
    var canScheduleResume: Bool {
        canResume && isPaused && uncertainText.isEmpty && !hasUnreadableRecovery && !hasUnsavedRecovery
    }
}

extension HaasPendingInputState {
    @MainActor init(delivery: HaasInputDelivery, canResume: Bool) {
        isVisible = delivery.hasRecovery
        errorMessage = delivery.recoveryError
        pendingText = delivery.pendingText
        uncertainText = delivery.uncertainText
        isPaused = delivery.isPaused
        hasUnreadableRecovery = delivery.hasUnreadableRecovery
        hasUnsavedRecovery = delivery.hasUnsavedRecovery
        resumeCountdown = delivery.resumeCountdown
        self.canResume = canResume
        if hasUnreadableRecovery {
            statusMessage = "入力確認待ちの記録を読み込めません。元の記録は保持しています。"
        } else if hasUnsavedRecovery {
            statusMessage = "入力確認待ちを保存できていません。表示中の文章を保持しています。"
        } else if pendingText.isEmpty, !uncertainText.isEmpty {
            let message = "入力先の文章を確認してください。この文は自動で再送しません。"
            statusMessage = errorMessage == nil ? message + "新しい録音は開始できます。" : message
        } else {
            statusMessage = delivery.message.isEmpty ? "確定した区間を入力しています。" : delivery.message
        }
    }
}

struct HaasPendingInputActions {
    let acknowledge: () -> Void
    let copy: () -> Void
    let scheduleResume: () -> Void
    let cancelResume: () -> Void
}

@MainActor
struct HaasPendingInputView: View {
    @ObservedObject var delivery: HaasInputDelivery = .shared
    var canResume = true

    var body: some View {
        let state = HaasPendingInputState(delivery: delivery, canResume: canResume)
        if state.isVisible {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    HaasPendingInputBody(state: state)
                }
                .frame(maxHeight: 160)
                HaasPendingInputControls(state: state, actions: HaasPendingInputActions(
                    acknowledge: delivery.acknowledgeUncertainInput,
                    copy: { delivery.copyPending() },
                    scheduleResume: delivery.scheduleResume,
                    cancelResume: delivery.cancelScheduledResume
                ))
            }
            .padding(12)
            .accessibilityIdentifier("haasPendingInput")
        }
    }
}

struct HaasPendingInputBody: View {
    let state: HaasPendingInputState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = state.errorMessage, error != state.statusMessage {
                Label {
                    Text(error).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if !state.uncertainText.isEmpty {
                textSection("入力済みか確認が必要な文", text: state.uncertainText, uncertain: true)
            }
            if !state.pendingText.isEmpty {
                textSection("まだ入力していない文", text: state.pendingText, uncertain: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func textSection(_ title: String, text: String, uncertain: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: uncertain ? "questionmark.circle" : "text.alignleft")
                .font(.caption.weight(.semibold))
                .foregroundStyle(uncertain ? Color.orange : Color.secondary)
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct HaasPendingInputControls: View {
    let state: HaasPendingInputState
    let actions: HaasPendingInputActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.uncertainText.isEmpty {
                Button("入力先を確認済み", action: actions.acknowledge)
                    .disabled(!state.canAcknowledge)
            }
            if !state.pendingText.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { pendingControls }
                    VStack(alignment: .leading, spacing: 8) { pendingControls }
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var pendingControls: some View {
        Button("未入力分をコピー", action: actions.copy)
        if let countdown = state.resumeCountdown {
            Button("再開を取消 (\(countdown)秒)", action: actions.cancelResume)
        } else {
            Button("3秒後に選択した欄で再開", action: actions.scheduleResume)
                .disabled(!state.canScheduleResume)
        }
    }
}
