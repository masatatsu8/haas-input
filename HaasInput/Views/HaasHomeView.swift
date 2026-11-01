import SwiftData
import SwiftUI

@MainActor
struct HaasHomeView: View {
    @ObservedObject var app: HaasAppModel
    @ObservedObject var engine: HaasEngine
    @ObservedObject var shortcuts: RecordingShortcutManager
    @ObservedObject private var preparation = HaasModelPreparation.shared
    @ObservedObject private var delivery: HaasInputDelivery
    @ObservedObject private var permissions: HaasPermissions
    @Query private var recent: [Transcription]

    init(app: HaasAppModel, engine: HaasEngine, shortcuts: RecordingShortcutManager) {
        self.app = app
        self.engine = engine
        self.shortcuts = shortcuts
        _delivery = ObservedObject(wrappedValue: engine.inputDelivery)
        _permissions = ObservedObject(wrappedValue: app.permissions)
        var descriptor = FetchDescriptor<Transcription>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = 5
        _recent = Query(descriptor)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("声を、そのまま入力へ")
                        .font(.largeTitle.bold())
                    Text("日本語の音声をこのMacで認識し、確定した区間からカーソル位置へ入力します。")
                        .foregroundStyle(.secondary)
                }

                GroupBox("録音") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label(engine.recordingState.displayName, systemImage: engine.recordingState == .recording ? "waveform" : "mic")
                                .font(.headline)
                            Spacer()
                            Button(recordingButtonTitle) {
                                Task {
                                    if engine.recordingState == .starting { await engine.cancelRecording() }
                                    else { await engine.toggleRecording() }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(engine.recordingState == .transcribing || engine.recordingState == .busy
                                || (engine.recordingState == .idle && (!preparation.isReady || !permissions.microphoneGranted)))
                            .accessibilityIdentifier("haasHomeRecording")
                        }
                        HStack {
                            Text("録音ショートカット")
                            Spacer()
                            Text(ShortcutStore.shortcut(for: .primaryRecording)?.displayString ?? "未設定")
                                .font(.headline.monospaced())
                            Text(shortcuts.primaryRecordingShortcutMode.displayName)
                                .foregroundStyle(.secondary)
                        }
                        Text("入力先の欄を選んでからショートカットで録音してください。この画面から始めた録音は、認識結果をコピーして使えます。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let error = engine.errorMessage {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        }
                        if engine.hasUnsavedHistory {
                            HStack {
                                Button("履歴の保存を再試行") { engine.retrySavingHistory() }
                                Button("認識結果をコピー") { engine.copyLastTranscription() }
                            }
                        }
                        if delivery.hasRecovery { HaasPendingInputView(delivery: delivery, canResume: engine.recordingState == .idle || engine.recordingState == .recording) }
                    }
                    .padding(8)
                }

                HaasPermissionView(permissions: permissions)
                GroupBox("認識データ") { HaasModelPreparationView().padding(8) }

                GroupBox("最近の履歴") {
                    VStack(alignment: .leading, spacing: 12) {
                        if recent.isEmpty {
                            Text("まだ録音履歴はありません。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(recent) { item in
                            Button {
                                app.selectedHistoryID = item.id
                                app.selectedDestination = .history
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(item.timestamp, format: .dateTime.month().day().hour().minute())
                                        Spacer()
                                        Text(item.historyStatusLabel)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    Text(verbatim: item.preferredHistoryText)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        Button("履歴をすべて見る") { app.selectedDestination = .history }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
            .padding(26)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
    }

    private var recordingButtonTitle: String {
        switch engine.recordingState {
        case .idle: "録音を開始"
        case .starting: "準備を取り消す"
        case .recording: "録音を終了"
        case .transcribing, .busy: "処理中…"
        }
    }
}

@MainActor
struct HaasPermissionView: View {
    @ObservedObject var permissions: HaasPermissions

    var body: some View {
        if !permissions.microphoneGranted || !permissions.accessibilityGranted {
            GroupBox("はじめに必要な許可") {
                VStack(alignment: .leading, spacing: 12) {
                    if !permissions.microphoneGranted {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("マイク").font(.headline)
                                Text("音声を認識するために必要です。")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("マイクの許可を確認", action: permissions.requestMicrophone)
                        }
                    }
                    if !permissions.accessibilityGranted {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("アクセシビリティ").font(.headline)
                                Text("ショートカットと、ほかのアプリへの文字入力に使います。")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("システム設定を開く", action: permissions.requestAccessibility)
                        }
                    }
                    Text("許可を変更したら、このアプリへ戻ってください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }
        }
    }
}
