import SwiftUI

struct HaasVocabularyEditor: View {
    let entry: HaasVocabularyEntry?
    @ObservedObject var store: HaasSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var writtenForm: String
    @State private var readings: String
    @State private var category: HaasVocabularyCategory
    @State private var errorMessage: String?
    @Environment(\.haasTextScale) private var textScale

    init(entry: HaasVocabularyEntry?, store: HaasSettingsStore) {
        self.entry = entry
        self.store = store
        _writtenForm = State(initialValue: entry?.writtenForm ?? "")
        _readings = State(initialValue: entry?.readings.joined(separator: ", ") ?? "")
        _category = State(initialValue: entry?.category ?? .company)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry == nil ? "Haas辞書に追加" : "Haas辞書の項目を編集")
                .haasFont(.headline)
            VStack(alignment: .leading, spacing: 5) {
                Text("正式表記")
                TextField("例: 日本橋研究所", text: $writtenForm)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("haasWrittenForm")
                Text("英字の大文字小文字、数字、空白も入力した表記で保存します。")
                    .haasFont(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("読み・別表記")
                TextField("例: ニホンバシケンキュウジョ", text: $readings)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("haasReadings")
                Text("複数の読み・別表記は半角カンマで区切ります。実際に誤認識される表記も登録できますが、短い別表記は一般語の誤変換につながる場合があります。正式表記のまま認識できる語は空欄にできます。")
                    .haasFont(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Picker("種類", selection: $category) {
                    ForEach(HaasVocabularyCategory.allCases) { category in
                        Text(category.displayName).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("haasVocabularyCategory")
                Text("種類は辞書の整理用です。認識には正式表記と読み・別表記を使います。")
                    .haasFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Text(errorMessage)
                    .haasFont(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(writtenForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("haasSaveVocabulary")
            }
        }
        .padding(24)
        .frame(width: 480 * textScale)
    }

    private func save() {
        do {
            try store.saveEntry(
                id: entry?.id,
                writtenForm: writtenForm,
                readings: readings.components(separatedBy: ","),
                category: category
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
