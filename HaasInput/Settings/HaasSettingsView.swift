import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
struct HaasSettingsView: View {
    @ObservedObject var app: HaasAppModel
    @ObservedObject var engine: HaasEngine
    @ObservedObject var shortcuts: RecordingShortcutManager
    @ObservedObject var presentation: HaasRecorderPresentation

    var body: some View {
        TabView(selection: $app.selectedSettingsTab) {
            HaasGeneralSettingsView(app: app, engine: engine, shortcuts: shortcuts, presentation: presentation)
                .tabItem { Label("操作と表示", systemImage: "keyboard") }
                .tag(HaasSettingsTab.general)
            AudioSetupView()
                .disabled(engine.recordingState != .idle)
                .tabItem { Label("録音", systemImage: "mic") }
                .tag(HaasSettingsTab.audio)
            HaasAboutView()
                .tabItem { Label("このアプリについて", systemImage: "info.circle") }
                .tag(HaasSettingsTab.about)
        }
        .padding(12)
    }
}

enum HaasSettingsTab: String {
    case general, audio, about
}

@MainActor
private struct HaasGeneralSettingsView: View {
    @ObservedObject var app: HaasAppModel
    @ObservedObject var engine: HaasEngine
    @ObservedObject var shortcuts: RecordingShortcutManager
    @ObservedObject var presentation: HaasRecorderPresentation
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @AppStorage(HaasPunctuationMode.settingsKey) private var punctuationMode = HaasPunctuationMode.fast
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @AppStorage("clipboardRestoreDelay") private var clipboardRestoreDelay = 2.0
    @AppStorage(AppAppearancePreference.userDefaultsKey) private var appearance = AppAppearancePreference.system
    @AppStorage(CleanupSettingsKeys.isTranscriptionCleanupEnabled) private var transcriptCleanup = true
    @AppStorage(CleanupSettingsKeys.transcriptionRetentionMinutes) private var transcriptRetention = 10080
    @AppStorage(CleanupSettingsKeys.isAudioCleanupEnabled) private var audioCleanup = false
    @AppStorage(CleanupSettingsKeys.audioRetentionPeriod) private var audioRetention = 7
    @State private var punctuationAvailability = ""
    @State private var cancelRecorderID = UUID()

    var body: some View {
        Form {
            Section("録音ショートカット") {
                HStack {
                    Text("主なショートカット")
                    Spacer()
                    modePicker(selection: $shortcuts.primaryRecordingShortcutMode)
                    ShortcutRecorder(action: .primaryRecording) {
                        shortcuts.primaryRecordingShortcut = .custom
                        shortcuts.updateShortcutStatus()
                    }
                }
                if shortcuts.secondaryRecordingShortcut != .none {
                    HStack {
                        Text("予備のショートカット")
                        Spacer()
                        modePicker(selection: $shortcuts.secondaryRecordingShortcutMode)
                        ShortcutRecorder(action: .secondaryRecording) {
                            shortcuts.secondaryRecordingShortcut = .custom
                            shortcuts.updateShortcutStatus()
                        }
                        Button {
                            shortcuts.secondaryRecordingShortcut = .none
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .help("予備のショートカットを外す")
                    }
                } else {
                    Button("予備のショートカットを追加") { shortcuts.secondaryRecordingShortcut = .custom }
                }
                Text("入力先を選んでから使います。キーの組み合わせや、修飾キーだけの操作も登録できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(engine.recordingState != .idle)

            Section("ほかの操作") {
                LabeledContent("直前の認識結果を入力") {
                    ShortcutRecorder(action: .pasteLastTranscription) { shortcuts.updateShortcutStatus() }
                }
                LabeledContent("履歴を開く") {
                    ShortcutRecorder(action: .openQuickHistory) { shortcuts.updateShortcutStatus() }
                }
                LabeledContent("録音を取り消す") {
                    HStack {
                        ShortcutRecorder(
                            action: .cancelRecorder,
                            defaultShortcut: .key(keyCode: UInt16(kVK_Escape), modifierFlags: [])
                        ) { shortcuts.updateShortcutStatus() }
                        .id(cancelRecorderID)
                        Button("初期設定に戻す") {
                            ShortcutStore.setShortcut(nil, for: .cancelRecorder)
                            RecorderPanelShortcutManager.resetEscapeConfirmationHint()
                            shortcuts.updateShortcutStatus()
                            cancelRecorderID = UUID()
                        }
                    }
                }
                Text("標準の取消操作は、録音パネルが表示されている間にEscを2回押します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(engine.recordingState != .idle)

            Section("句読点") {
                Picker("補い方", selection: $punctuationMode) {
                    ForEach(HaasPunctuationMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(punctuationMode.description).font(.callout).foregroundStyle(.secondary)
                if punctuationMode.usesOnDeviceModel {
                    Text(punctuationAvailability).font(.caption).foregroundStyle(.secondary)
                }
                Text("変更は次の録音から反映されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("表示") {
                Picker("録音パネルの位置", selection: $presentation.recorderPanelStyle) {
                    ForEach(RecorderPanelStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Toggle("録音中に途中の認識結果を表示", isOn: $showLiveTranscript)
                Picker("外観", selection: $appearance) {
                    ForEach(AppAppearancePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
            }

            Section("クリップボード") {
                Picker("入力後に元の内容へ戻すまで", selection: $clipboardRestoreDelay) {
                    Text("0.25秒").tag(0.25)
                    Text("0.5秒").tag(0.5)
                    Text("1秒").tag(1.0)
                    Text("2秒").tag(2.0)
                    Text("3秒").tag(3.0)
                    Text("4秒").tag(4.0)
                    Text("5秒").tag(5.0)
                }
                Text("文字入力に一時的にクリップボードを使い、その後に元の内容へ戻します。途中で別の内容をコピーした場合は、その新しい内容を保持します。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("履歴の保存期間") {
                Toggle("保存期間を過ぎた履歴と録音を自動で削除", isOn: $transcriptCleanup)
                if transcriptCleanup {
                    Picker("履歴を残す期間", selection: $transcriptRetention) {
                        Text("録音終了後すぐ").tag(0)
                        Text("1時間").tag(60)
                        Text("1日").tag(1440)
                        Text("3日").tag(4320)
                        Text("7日").tag(10080)
                        if ![0, 60, 1440, 4320, 10080].contains(transcriptRetention) {
                            Text("\(transcriptRetention)分").tag(transcriptRetention)
                        }
                    }
                } else {
                    Toggle("本文を残して古い録音ファイルだけ削除", isOn: $audioCleanup)
                    if audioCleanup {
                        Picker("録音を残す期間", selection: $audioRetention) {
                            ForEach([1, 3, 7, 14, 30, 90], id: \.self) { days in
                                Text("\(days)日").tag(days)
                            }
                            if ![1, 3, 7, 14, 30, 90].contains(audioRetention) {
                                Text("\(audioRetention)日").tag(audioRetention)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("削除した録音はゴミ箱へ移します。")
                    Text("自動整理は録音終了後に行います。入力確認待ちの文章は、履歴を削除しても確認が終わるまで残ります。")
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("起動") {
                Toggle("Macへのログイン時に起動", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .disabled(launchAtLogin.isUpdating)
                if let message = launchAtLogin.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin.refresh()
            refreshPunctuationAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
            refreshPunctuationAvailability()
        }
        .onChange(of: punctuationMode) { _, _ in refreshPunctuationAvailability() }
        .onChange(of: appearance) { _, value in value.apply() }
    }

    private func modePicker(selection: Binding<RecordingShortcutManager.Mode>) -> some View {
        Picker("録音の操作", selection: selection) {
            ForEach(RecordingShortcutManager.Mode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 180)
    }

    private func refreshPunctuationAvailability() {
        punctuationAvailability = HaasPunctuationWorker.forMode(punctuationMode).unavailableReason ?? "このMacで利用できます。"
    }
}
