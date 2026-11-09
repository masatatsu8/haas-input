import SwiftData
import SwiftUI

struct HaasWordReplacementView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WordReplacement.dateAdded, order: .reverse) private var rules: [WordReplacement]
    @State private var searchText = ""
    @State private var editor: EditorRequest?
    @State private var ruleToDelete: WordReplacement?
    @State private var errorMessage: String?
    @AppStorage(HaasTextScaleSettingsKeys.mainWindow) private var textScale = HaasTextScale.standard

    private struct EditorRequest: Identifiable {
        let id = UUID()
        let rule: WordReplacement?
    }
    private var visibleRules: [WordReplacement] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rules.filter {
            query.isEmpty || $0.originalText.localizedStandardContains(query)
                || $0.replacementText.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("置換ルール").haasFont(.headline)
                Spacer()
                Button("追加", systemImage: "plus") { editor = EditorRequest(rule: nil) }
                    .buttonStyle(.borderedProminent)
            }
            Text("認識が確定した文章に適用します。複数の元の語は半角カンマで区切れます。変更は次の録音から反映されます。")
                .haasFont(.caption).foregroundStyle(.secondary)
            TextField("元の語・置換先を検索", text: $searchText)
                .textFieldStyle(.roundedBorder)
            Text("表示 \(visibleRules.count) / 全 \(rules.count) 件")
                .haasFont(.caption).foregroundStyle(.secondary)
            Table(visibleRules) {
                TableColumn("元の語") { rule in
                    Text(verbatim: rule.originalText).lineLimit(1).help(rule.originalText)
                }
                TableColumn("置換先") { rule in
                    Text(verbatim: rule.replacementText).lineLimit(1).help(rule.replacementText)
                }
                TableColumn("操作") { rule in
                    HStack {
                        Button("編集") { editor = EditorRequest(rule: rule) }
                        Button(role: .destructive) { ruleToDelete = rule } label: {
                            Image(systemName: "trash")
                        }
                        .help("置換ルールを削除")
                        .accessibilityLabel("\(rule.originalText) の置換ルールを削除")
                    }
                    .buttonStyle(.borderless)
                }
                .width(80 * textScale.factor)
            }
            .overlay {
                if visibleRules.isEmpty {
                    Text(rules.isEmpty ? "置換ルールはまだありません。" : "検索条件に一致する置換ルールはありません。")
                        .foregroundStyle(.secondary).padding()
                }
            }
        }
        .sheet(item: $editor) { request in
            HaasWordReplacementEditor(rule: request.rule)
                .haasTextScaleRoot(textScale)
        }
        .alert("置換ルールを削除しますか？", isPresented: Binding(
            get: { ruleToDelete != nil }, set: { if !$0 { ruleToDelete = nil } }
        )) {
            Button("キャンセル", role: .cancel) { ruleToDelete = nil }
            Button("削除", role: .destructive) {
                if let rule = ruleToDelete {
                    errorMessage = HaasWordReplacementStore.removeWordReplacement(rule, context: context)
                }
                ruleToDelete = nil
            }
        } message: {
            Text(ruleToDelete.map { "\($0.originalText) → \($0.replacementText)" } ?? "")
        }
        .alert("置換ルール", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct HaasWordReplacementEditor: View {
    let rule: WordReplacement?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var original: String
    @State private var replacement: String
    @State private var errorMessage: String?
    @Environment(\.haasTextScale) private var textScale

    init(rule: WordReplacement?) {
        self.rule = rule
        _original = State(initialValue: rule?.originalText ?? "")
        _replacement = State(initialValue: rule?.replacementText ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(rule == nil ? "置換ルールを追加" : "置換ルールを編集").haasFont(.headline)
            Text("元の語")
            TextField("例: 音声にゅうりょく, 音声入浴", text: $original)
                .textFieldStyle(.roundedBorder)
            Text("置換先")
            TextField("例: 音声入力", text: $replacement)
                .textFieldStyle(.roundedBorder)
            Text("同じ元の語を別の置換先へ登録することや、元へ戻る循環したルールはできません。")
                .haasFont(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).haasFont(.callout) }
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(WordReplacementVariants.parse(original).isEmpty || replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 480 * textScale)
    }

    private func save() {
        if let rule {
            errorMessage = HaasWordReplacementStore.updateWordReplacement(rule, original: original, replacementText: replacement, context: context)
        } else {
            do {
                let existing = try context.fetch(FetchDescriptor<WordReplacement>())
                errorMessage = HaasWordReplacementStore.addWordReplacement(original: original, replacement: replacement, existing: existing, context: context)
            } catch { errorMessage = "置換ルールを読み込めませんでした。" }
        }
        if errorMessage == nil { dismiss() }
    }
}
