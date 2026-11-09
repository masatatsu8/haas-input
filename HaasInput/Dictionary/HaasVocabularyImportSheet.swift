import SwiftUI

struct HaasVocabularyImportSheet: View {
    let preview: HaasVocabularyImportPreview
    @ObservedObject var store: HaasSettingsStore
    let onImported: (HaasVocabularyImportResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var replacements = Set<String>()
    @State private var errorMessage: String?
    @Environment(\.haasTextScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Haas辞書を読み込む").haasFont(.headline)
            Text("追加 \(preview.addedCount) 件・同じ登録 \(preview.unchangedCount) 件・内容の違う登録 \(preview.conflictCount) 件")
                .haasFont(.callout)
            Text("内容が違う登録は現在の辞書を保持します。更新したい項目だけ選んでください。")
                .haasFont(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(preview.items) { item in
                        previewRow(item)
                        Divider()
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .haasFont(.callout)
            }
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("読み込む") { importVocabulary() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.addedCount == 0 && replacements.isEmpty)
                    .accessibilityIdentifier("haasConfirmImport")
            }
        }
        .padding(24)
        .haasSheetFrame(width: 580, height: 520, scale: textScale)
    }

    @ViewBuilder
    private func previewRow(_ item: HaasVocabularyImportPreview.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch item.status {
            case .added:
                Label("追加", systemImage: "plus.circle")
                entryDescription(item.incoming)
            case .unchanged:
                Label("変更なし", systemImage: "equal.circle")
                    .foregroundStyle(.secondary)
                entryDescription(item.incoming)
            case .conflict:
                if let existing = item.existing {
                    Text("現在の登録").haasFont(.caption).foregroundStyle(.secondary)
                    entryDescription(existing)
                }
                Text("共有ファイルの登録").haasFont(.caption).foregroundStyle(.secondary)
                entryDescription(item.incoming)
                Toggle("この内容で現在の登録を更新する", isOn: Binding(
                    get: { replacements.contains(item.id) },
                    set: { replace in
                        if replace { replacements.insert(item.id) } else { replacements.remove(item.id) }
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func entryDescription(_ entry: HaasVocabularyEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: entry.writtenForm).fontWeight(.medium)
            Text(entry.readings.isEmpty ? "読みの指定なし" : entry.readings.joined(separator: " / "))
                .haasFont(.callout)
                .foregroundStyle(.secondary)
            Text(entry.category.displayName).haasFont(.caption).foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }

    private func importVocabulary() {
        do {
            let result = try store.applyImport(preview, replacing: replacements)
            dismiss()
            onImported(result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
