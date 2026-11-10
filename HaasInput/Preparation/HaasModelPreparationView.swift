import AppKit
import SwiftUI

struct HaasModelPreparationView: View {
    @ObservedObject private var preparation = HaasModelPreparation.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .haasFont(.callout, weight: .medium)

            if preparation.isWorking {
                if let progress = preparation.progress,
                    progress.phase == .downloading,
                    progress.totalBytes > 0
                {
                    ProgressView(value: Double(progress.completedBytes), total: Double(progress.totalBytes))
                    Text("\(formattedBytes(progress.completedBytes)) / \(formattedBytes(progress.totalBytes))")
                        .haasFont(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if case .failed(let message) = preparation.state {
                Text(message)
                    .haasFont(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if !preparation.isReady {
                Text("必要なモデルが見つからない場合は、約 0.66 GB をダウンロードします。準備後の音声認識は Mac 内で処理します。")
                    .haasFont(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if preparation.isWorking {
                    if case .cancelled = preparation.state {
                        Text("キャンセルしています…")
                            .haasFont(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("キャンセル", action: preparation.cancel)
                            .accessibilityIdentifier("haasCancelModelDownload")
                    }
                } else if !preparation.isReady {
                    Button(actionTitle, action: preparation.prepare)
                        .accessibilityIdentifier("haasPrepareModels")
                    if preparation.hasCustomPaths {
                        Button("自動設定に戻して準備", action: preparation.useAutomaticConfiguration)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .onAppear { preparation.refreshIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            preparation.refreshIfNeeded()
        }
    }

    private var title: String {
        switch preparation.state {
        case .idle:
            return "Haas Q8 の準備"
        case .preparing:
            switch preparation.progress?.phase {
            case .downloading:
                return "音声認識モデルをダウンロードしています"
            case .verifying:
                return "モデルの内容を検証しています"
            case .checking, nil:
                return "必要なモデルを確認しています"
            }
        case .ready:
            return "Haas Q8 の準備ができています"
        case .cancelled:
            return "モデルの準備をキャンセルしました"
        case .failed:
            return "Haas Q8 の準備を完了できませんでした"
        }
    }

    private var symbol: String {
        switch preparation.state {
        case .ready: return "checkmark.circle"
        case .cancelled: return "pause.circle"
        case .failed: return "exclamationmark.triangle"
        case .idle, .preparing: return "arrow.down.circle"
        }
    }

    private var actionTitle: String {
        switch preparation.state {
        case .failed, .cancelled: return "再試行"
        default: return "モデルを準備"
        }
    }

    private func formattedBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
