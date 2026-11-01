import AppKit
import SwiftData
import SwiftUI
import os

struct HaasHistoryView: View {
    @Binding var selectedID: UUID?
    var activeAudioURL: URL? = nil
    @Environment(\.modelContext) private var context
    @Query(sort: \Transcription.timestamp, order: .reverse) private var transcriptions: [Transcription]
    @ObservedObject private var delivery = HaasInputDelivery.shared
    @State private var searchText = ""
    @State private var selection = Set<UUID>()
    @State private var showDeleteConfirmation = false
    @State private var showsRecovery = false
    @State private var errorMessage: String?
    @State private var copyMessage: String?
    private let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "History")

    private var visibleRows: [Transcription] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcriptions.filter {
            query.isEmpty || $0.text.localizedStandardContains(query)
                || ($0.enhancedText?.localizedStandardContains(query) ?? false)
        }
    }
    private var selectedRows: [Transcription] { visibleRows.filter { selection.contains($0.id) } }
    private var detail: Transcription? { selectedRows.count == 1 ? selectedRows.first : nil }
    private var listSelection: Binding<Set<UUID>> {
        Binding(get: { selection }, set: { ids in
            selection = ids
            selectedID = ids.count == 1 ? ids.first : nil
            copyMessage = nil
        })
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("履歴の文章を検索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("haasHistorySearch")
                Button("入力確認待ち (\(delivery.archivedRecoveries.count))", systemImage: "exclamationmark.bubble") {
                    showsRecovery = true
                }
            }
            HStack {
                Text(selection.isEmpty ? "\(visibleRows.count) 件" : "\(selection.count) 件を選択中")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(selection.isEmpty ? "表示中の履歴をCSVへ" : "選択した履歴をCSVへ") { exportRows() }
                    .disabled(visibleRows.isEmpty)
                Button("削除", role: .destructive) { showDeleteConfirmation = true }
                    .disabled(selectedRows.isEmpty)
            }
            HSplitView {
                List(selection: listSelection) {
                    ForEach(visibleRows, id: \.id) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(row.timestamp, format: .dateTime.month().day().hour().minute())
                                Spacer()
                                Text(row.historyStatusLabel)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: row.preferredHistoryText)
                                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                        .tag(row.id)
                    }
                }
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                .overlay {
                    if visibleRows.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "履歴はまだありません" : "一致する履歴がありません",
                            systemImage: searchText.isEmpty ? "waveform" : "magnifyingglass",
                            description: Text(searchText.isEmpty ? "録音した文章はここで確認できます。" : "別の語で検索してください。")
                        )
                    }
                }
                if let detail {
                    detailView(detail)
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        selection.count > 1 ? "複数の履歴を選択中" : "履歴を選択してください",
                        systemImage: "doc.text",
                        description: Text(selection.count > 1 ? "まとめて書き出すか削除できます。" : "文章のコピーや録音の再生ができます。")
                    )
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(20)
        .onAppear { selectRequestedHistory() }
        .onChange(of: selectedID) { _, _ in selectRequestedHistory() }
        .onChange(of: visibleRows.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .sheet(isPresented: $showsRecovery) {
            HaasRecoveryHistoryView(
                records: delivery.archivedRecoveries, errorMessage: delivery.recoveryError,
                onCopy: { delivery.copyArchivedRecovery(id: $0, kind: $1) },
                onAcknowledge: { delivery.acknowledgeArchivedRecovery(id: $0) },
                onOpenTranscription: { id in
                    showsRecovery = false
                    if transcriptions.contains(where: { $0.id == id }) {
                        searchText = ""
                        selection = [id]
                        selectedID = id
                    } else { errorMessage = "対応する録音履歴は見つかりません。入力確認待ちの文章は残っています。" }
                },
                onClose: { showsRecovery = false }
            )
            .frame(width: 700, height: 560)
        }
        .alert("選択した履歴を削除しますか？", isPresented: $showDeleteConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive, action: deleteRows)
        } message: {
            Text("\(selectedRows.count) 件の履歴を削除します。このアプリが保存した録音はゴミ箱へ移します。入力確認待ちの記録は残します。")
        }
        .alert("履歴の操作を完了できませんでした", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func detailView(_ row: Transcription) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(row.timestamp, format: .dateTime.year().month().day().hour().minute()).font(.headline)
                Spacer()
                Button("コピー", systemImage: "doc.on.doc") {
                    if ClipboardManager.setClipboard(row.preferredHistoryText) { copyMessage = "コピーしました" }
                    else { errorMessage = "クリップボードへコピーできませんでした。" }
                }
            }
            HStack {
                Text(row.historyStatusLabel)
                Text("録音 \(row.duration.formatted(.number.precision(.fractionLength(1)))) 秒")
                if let name = row.transcriptionModelName { Text(verbatim: name) }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let audio = row.availableHistoryAudioURL {
                HaasHistoryAudioPlayer(url: audio)
            } else {
                Text("再生できる録音ファイルはありません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let copyMessage { Text(copyMessage).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                Text(verbatim: row.preferredHistoryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if let enhanced = row.enhancedText, !enhanced.isEmpty, row.preferredHistoryText != row.text {
                DisclosureGroup("保存されている認識結果") {
                    Text(verbatim: row.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func selectRequestedHistory() {
        guard let selectedID, transcriptions.contains(where: { $0.id == selectedID }), !selection.contains(selectedID) else { return }
        searchText = ""
        selection = [selectedID]
        copyMessage = nil
    }

    private func exportRows() {
        do { try HaasHistoryCSV.export(selection.isEmpty ? visibleRows : selectedRows) }
        catch {
            logger.error("History export failed: \(String(describing: error), privacy: .private)")
            errorMessage = "CSVを書き出せませんでした。保存先を確認してください。"
        }
    }

    private func deleteRows() {
        do {
            try HaasHistoryMaintenance.shared.delete(selectedRows, context: context, activeAudioURL: activeAudioURL)
            selection.removeAll()
            selectedID = nil
        } catch {
            logger.error("History deletion failed: \(String(describing: error), privacy: .private)")
            errorMessage = (error as? HaasHistoryError)?.errorDescription ?? "履歴を削除できませんでした。"
        }
    }
}
