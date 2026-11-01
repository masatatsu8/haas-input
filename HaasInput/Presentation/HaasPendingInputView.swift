import SwiftUI

struct HaasPendingInputView: View {
    @ObservedObject var delivery: HaasInputDelivery = .shared
    var canResume = true

    var body: some View {
        if delivery.hasRecovery {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let error = delivery.recoveryError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                        if !delivery.uncertainText.isEmpty {
                            Text("入力済みか確認が必要な文")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text(verbatim: delivery.uncertainText)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        if !delivery.pendingText.isEmpty {
                            Text("まだ入力していない文")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(verbatim: delivery.pendingText)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)

                if !delivery.uncertainText.isEmpty {
                    Button("入力先を確認済み") { delivery.acknowledgeUncertainInput() }
                        .disabled(!delivery.isPaused || delivery.hasUnreadableRecovery)
                }

                if !delivery.pendingText.isEmpty {
                    HStack {
                        Button("未入力分をコピー") { delivery.copyPending() }
                        if let countdown = delivery.resumeCountdown {
                            Button("再開を取消 (\(countdown)秒)") { delivery.cancelScheduledResume() }
                        } else {
                            Button("3秒後に選択した欄で再開") { delivery.scheduleResume() }
                                .disabled(!canResume || !delivery.isPaused || !delivery.uncertainText.isEmpty
                                    || delivery.hasUnreadableRecovery || delivery.hasUnsavedRecovery)
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(12)
        }
    }

    private var statusMessage: String {
        if delivery.hasUnreadableRecovery {
            return "入力確認待ちの記録を読み込めません。元の記録は保持しています。"
        }
        if delivery.hasUnsavedRecovery {
            return "入力確認待ちを保存できていません。表示中の文章を保持しています。"
        }
        if delivery.pendingText.isEmpty, !delivery.uncertainText.isEmpty {
            let message = "入力先の文章を確認してください。この文は自動で再送しません。"
            return delivery.recoveryError == nil ? message + "新しい録音は開始できます。" : message
        }
        return delivery.message.isEmpty ? "確定した区間を入力しています。" : delivery.message
    }
}
