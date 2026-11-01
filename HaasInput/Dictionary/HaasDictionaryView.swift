import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import os

struct HaasDictionaryView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case vocabulary = "Haas辞書"
        case replacements = "置換ルール"
        var id: Self { self }
    }
    @State private var section: Section = .vocabulary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("辞書の種類", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            if section == .vocabulary {
                HaasVocabularySection()
            } else {
                HaasWordReplacementView()
            }
        }
        .padding(20)
    }
}

private struct HaasVocabularySection: View {
    @ObservedObject private var store = HaasSettingsStore.shared
    @State private var editor: EditorRequest?
    @State private var entryToDelete: HaasVocabularyEntry?
    @State private var errorMessage: String?
    @State private var importPreview: HaasVocabularyImportPreview?
    @State private var transferMessage: String?
    private let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "HaasDictionary")

    private struct EditorRequest: Identifiable {
        let id = UUID()
        let entry: HaasVocabularyEntry?
    }

    var body: some View {
        HaasVocabularyTable(
            entries: store.entries, loadError: store.loadError, transferMessage: transferMessage,
            onAdd: { editor = EditorRequest(entry: nil) },
            onEdit: { editor = EditorRequest(entry: $0) },
            onDelete: { entryToDelete = $0 }, onImport: importVocabulary, onExport: exportVocabulary
        )
        .sheet(item: $editor) { request in
            HaasVocabularyEditor(entry: request.entry, store: store)
        }
        .sheet(item: $importPreview) { preview in
            HaasVocabularyImportSheet(preview: preview, store: store) { result in
                transferMessage = result.message
            }
        }
        .alert("辞書の項目を削除しますか？", isPresented: Binding(
            get: { entryToDelete != nil },
            set: { if !$0 { entryToDelete = nil } }
        )) {
            Button("キャンセル", role: .cancel) { entryToDelete = nil }
            Button("削除", role: .destructive) {
                guard let entry = entryToDelete else { return }
                do { try store.removeEntry(id: entry.id) }
                catch { show(error) }
                entryToDelete = nil
            }
        } message: {
            Text(entryToDelete?.writtenForm ?? "")
        }
        .alert("辞書の操作を完了できませんでした", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func exportVocabulary() {
        do {
            let data = try store.exportVocabulary()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "Haas辞書.json"
            panel.title = "Haas辞書を書き出す"
            panel.message = "登録した正式表記・読み・種類だけを書き出します。"
            panel.prompt = "書き出す"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            transferMessage = "辞書を書き出しました: \(url.lastPathComponent)"
        } catch { show(error) }
    }

    private func importVocabulary() {
        do {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.title = "Haas辞書の共有ファイルを選択"
            panel.prompt = "読み込む"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size <= HaasVocabularyArchive.maximumFileBytes else {
                throw HaasVocabularyArchiveError.fileTooLarge
            }
            importPreview = try store.previewImport(Data(contentsOf: url, options: .mappedIfSafe))
        } catch { show(error) }
    }

    private func show(_ error: Error) {
        if error is HaasVocabularyError || error is HaasVocabularyArchiveError {
            errorMessage = error.localizedDescription
        } else {
            logger.error("Dictionary transfer failed: \(String(describing: error), privacy: .private)")
            errorMessage = "辞書ファイルを読み書きできませんでした。ファイルと保存先を確認してください。"
        }
    }
}
