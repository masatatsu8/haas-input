import SwiftUI

struct HaasRecoveryHistoryView: View {
    let records: [HaasRecoveryRecord]
    let errorMessage: String?
    let onCopy: (UUID, HaasRecoveryCopyKind) -> Void
    let onAcknowledge: (UUID) -> Void
    let onOpenTranscription: (UUID) -> Void
    let onClose: () -> Void

    @State private var selectedRecordID: UUID?
    @State private var recordToAcknowledge: HaasRecoveryRecord?

    private var selectedRecord: HaasRecoveryRecord? {
        records.first { $0.id == selectedRecordID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("入力確認待ち (\(records.count))").haasFont(.headline)
                Spacer()
                Button("閉じる", action: onClose).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()

            if let record = selectedRecord {
                recordDetail(record)
            } else {
                recordList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: records.map(\.id)) { _, ids in
            if let selectedRecordID, !ids.contains(selectedRecordID) {
                self.selectedRecordID = nil
            }
        }
        .alert("この記録を確認済みにしますか？", isPresented: Binding(
            get: { recordToAcknowledge != nil },
            set: { if !$0 { recordToAcknowledge = nil } }
        ), presenting: recordToAcknowledge) { record in
            Button("キャンセル", role: .cancel) { recordToAcknowledge = nil }
            Button("確認済みにする") {
                onAcknowledge(record.id)
                recordToAcknowledge = nil
            }
        } message: { _ in
            Text("入力先の内容を確認・修正した場合だけ、確認済みにしてください。この記録を一覧から外します。コピーしただけなら、確認が終わるまで残してください。")
        }
    }

    private var recordList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("過去の録音で入力を確認できなかった文です。ここにある文を自動で再送することはありません。")
                    .haasFont(.callout)
                    .foregroundStyle(.secondary)
                if errorMessage == nil {
                    Text("過去の確認待ちを残したまま、新しい録音を開始できます。")
                        .haasFont(.callout)
                        .foregroundStyle(.secondary)
                }
                recoveryError

                if records.isEmpty, errorMessage == nil {
                    Text("過去の入力確認待ちはありません。")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                }

                ForEach(records) { record in
                    Button {
                        selectedRecordID = record.id
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(dateLabel(record.createdAt))
                                    .haasFont(.callout, weight: .semibold)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .haasFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !record.ledger.pendingText.isEmpty {
                                Text("未入力: \(record.ledger.pendingText.count) 文字")
                                    .haasFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !record.ledger.uncertainText.isEmpty {
                                Text("入力済みか要確認: \(record.ledger.uncertainText.count) 文字")
                                    .haasFont(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Text(verbatim: record.ledger.fullText)
                                .haasFont(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func recordDetail(_ record: HaasRecoveryRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    selectedRecordID = nil
                } label: {
                    Label("一覧へ戻る", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text(dateLabel(record.createdAt))
                    .haasFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            if let transcriptionID = record.transcriptionID {
                Button("録音履歴を開く") { onOpenTranscription(transcriptionID) }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    recoveryError
                    if !record.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("保存時の状況").haasFont(.caption, weight: .semibold)
                            Text(verbatim: record.message).haasFont(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    }
                    if !record.ledger.pendingText.isEmpty {
                        recoveryText(
                            title: "まだ入力していない文",
                            description: "必要な入力先へ手動で貼り付けてください。",
                            text: record.ledger.pendingText
                        )
                    }
                    if !record.ledger.uncertainText.isEmpty {
                        recoveryText(
                            title: "入力済みか確認が必要な文",
                            description: "入力先に同じ文がないか確認してから、必要な部分だけ貼り付けてください。自動再送はしません。",
                            text: record.ledger.uncertainText
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("コピーだけでは記録は消えません。入力先の確認が終わったら「確認済み」にしてください。")
                    .haasFont(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if !record.ledger.pendingText.isEmpty {
                        Button("未入力文をコピー") { onCopy(record.id, .pending) }
                    }
                    if !record.ledger.uncertainText.isEmpty {
                        Button("要確認文をコピー") { onCopy(record.id, .uncertain) }
                            .help("入力済みか不明な文をコピーします。記録は残ります。")
                    }
                }
                Button("この記録を確認済みにする") { recordToAcknowledge = record }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(16)
        }
    }

    private func recoveryText(title: String, description: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).haasFont(.headline)
            Text(description).haasFont(.caption).foregroundStyle(.secondary)
            Text(verbatim: text)
                .haasFont(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var recoveryError: some View {
        if let errorMessage {
            Text(errorMessage)
                .haasFont(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func dateLabel(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "日時不明"
    }
}
