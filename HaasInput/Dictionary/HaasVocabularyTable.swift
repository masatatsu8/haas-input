import SwiftUI

struct HaasVocabularyTable: View {
    let entries: [HaasVocabularyEntry]
    let loadError: String?
    let transferMessage: String?
    let onAdd: () -> Void
    let onEdit: (HaasVocabularyEntry) -> Void
    let onDelete: (HaasVocabularyEntry) -> Void
    let onImport: () -> Void
    let onExport: () -> Void

    @State private var searchText = ""
    @State private var category: HaasVocabularyCategory?

    private var filteredEntries: [HaasVocabularyEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (category == nil || entry.category == category)
                && (query.isEmpty || entry.writtenForm.localizedStandardContains(query)
                    || entry.readings.contains { $0.localizedStandardContains(query) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Haas辞書").font(.headline)
                Spacer()
                Menu {
                    Button("共有ファイルを読み込む…", action: onImport)
                        .accessibilityIdentifier("haasImportVocabulary")
                    Button("共有用ファイルを書き出す…", action: onExport)
                        .accessibilityIdentifier("haasExportVocabulary")
                } label: {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
                .help("辞書の項目だけを JSON ファイルで共有します。接続設定や録音は含まれません。")
                .disabled(loadError != nil)
                Button(action: onAdd) {
                    Label("追加", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(loadError != nil)
                .accessibilityIdentifier("haasAddVocabulary")
            }
            .controlSize(.small)

            Text("読み・別表記で認識を助け、対応する結果を正式表記へそろえます。変更は次の録音から反映されます。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("検索").font(.callout)
                    TextField("名称・読み・別表記", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("正式表記・読み・別表記を検索")
                        .accessibilityIdentifier("haasVocabularySearch")
                }
                Picker("種類", selection: $category) {
                    Text("すべて").tag(HaasVocabularyCategory?.none)
                    ForEach(HaasVocabularyCategory.allCases) { category in
                        Text(category.displayName).tag(Optional(category))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 190)
                .accessibilityIdentifier("haasVocabularyCategoryFilter")
            }
            .controlSize(.small)
            .disabled(loadError != nil)

            HStack {
                if loadError == nil {
                    Text("表示 \(filteredEntries.count) / 全 \(entries.count) 件")
                } else {
                    Text("辞書を読み込めません")
                }
                Spacer()
                if let transferMessage {
                    Text(transferMessage).lineLimit(1).help(transferMessage)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Table(filteredEntries) {
                TableColumn("正式表記") { entry in
                    Text(verbatim: entry.writtenForm)
                        .lineLimit(1)
                        .help(entry.writtenForm)
                }
                .width(min: 120, ideal: 150)

                TableColumn("読み・別表記") { entry in
                    let readings = entry.readings.joined(separator: " / ")
                    Text(readings.isEmpty ? "指定なし" : readings)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(readings.isEmpty ? "正式表記のまま認識する項目です。" : readings)
                }
                .width(min: 130, ideal: 160)

                TableColumn("種類") { entry in
                    Text(entry.category.displayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(entry.category.displayName)
                }
                .width(min: 110, ideal: 110)

                TableColumn("操作") { entry in
                    HStack(spacing: 8) {
                        Button("編集") { onEdit(entry) }
                            .accessibilityLabel("\(entry.writtenForm) を編集")
                        Button(role: .destructive) { onDelete(entry) } label: {
                            Image(systemName: "trash")
                        }
                        .help("\(entry.writtenForm) を削除")
                        .accessibilityLabel("\(entry.writtenForm) を削除")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .width(70)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .font(.system(size: 13))
            .frame(minHeight: 160, maxHeight: .infinity)
            .disabled(loadError != nil)
            .overlay {
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Color.red)
                        .padding(24)
                } else if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "character.book.closed").foregroundStyle(.secondary)
                        Text("辞書はまだ空です。辞書なしでも Haas を使えます。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("最初の項目を追加", action: onAdd)
                    }
                    .padding(20)
                } else if filteredEntries.isEmpty {
                    VStack(spacing: 8) {
                        Text("検索条件に一致する項目はありません。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("検索条件を解除") {
                            searchText = ""
                            category = nil
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
