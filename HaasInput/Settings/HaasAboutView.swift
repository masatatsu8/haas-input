import AppKit
import SwiftUI

@MainActor
struct HaasAboutView: View {
    @State private var licenseText: String?
    @State private var licenseTitle = ""
    @State private var copyMessage = ""
    @AppStorage(HaasTextScaleSettingsKeys.mainWindow) private var textScale = HaasTextScale.standard

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開発版"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(HaasAppConfiguration.name).haasFont(.largeTitle, weight: .bold)
                    Text("バージョン \(version)").foregroundStyle(.secondary)
                }
                Text("Haasによる日本語の音声入力アプリです。音声認識はこのMacで行います。認識データを同梱していない構成では、初回の取得に通信を使います。")
                Text("VoiceInkの録音・入力処理を基に、Haas専用に構成しています。")
                    .foregroundStyle(.secondary)
                GroupBox("診断") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("保存先を開く", action: HaasStorageLocation.open)
                        Button("診断情報をコピー") {
                            let system = ProcessInfo.processInfo.operatingSystemVersion
                            let report = "Haas音声入力 \(version)\nmacOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)\n" + ShortcutDiagnostics.healthReport()
                            copyMessage = ClipboardManager.setClipboard(report) ? "診断情報をコピーしました。" : "コピーできませんでした。"
                        }
                        Text("環境と操作状態をコピーします。認識本文や辞書の内容は含めません。")
                            .haasFont(.caption).foregroundStyle(.secondary)
                        if !copyMessage.isEmpty { Text(copyMessage).haasFont(.caption) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                GroupBox("ライセンス") {
                    VStack(alignment: .leading, spacing: 10) {
                        licenseButton("アプリとVoiceInk (GPL v3)", resource: "VOICEINK-LICENSE")
                        licenseButton("swift-atomics", resource: "SWIFT-ATOMICS-LICENSE")
                        licenseButton("MediaRemoteAdapter", resource: "MediaRemoteAdapter-Notices", fileExtension: "txt")
                        licenseButton("speech.cpp", resource: "SPEECH-LICENSE", subdirectory: "Haas")
                        licenseButton("ggml", resource: "GGML-LICENSE", subdirectory: "Haas")
                        licenseButton("cpp-httplib", resource: "CPP-HTTPLIB-LICENSE", subdirectory: "Haas")
                        licenseButton("miniaudio", resource: "MINIAUDIO-LICENSE", subdirectory: "Haas")
                        licenseButton("Haasモデル", resource: "HAAS-LICENSE", subdirectory: "Haas")
                        licenseButton("Silero VAD", resource: "SILERO-LICENSE", subdirectory: "Haas")
                        Link("ソースコード", destination: URL(string: "https://github.com/masatatsu8/haas-input")!)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
            .padding(26)
            .frame(maxWidth: 720 * textScale.factor, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: Binding(get: { licenseText != nil }, set: { if !$0 { licenseText = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(licenseTitle).haasFont(.headline)
                    Spacer()
                    Button("閉じる") { licenseText = nil }.keyboardShortcut(.cancelAction)
                }
                ScrollView {
                    Text(verbatim: licenseText ?? "")
                        .haasFont(.caption, design: .monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .haasSheetFrame(width: 680, height: 500, scale: textScale.factor)
            .haasTextScaleRoot(textScale)
        }
    }

    private func licenseButton(_ title: String, resource: String, fileExtension: String? = nil, subdirectory: String? = nil) -> some View {
        Button(title) {
            licenseTitle = title
            guard let url = Bundle.main.url(forResource: resource, withExtension: fileExtension, subdirectory: subdirectory),
                let contents = try? String(contentsOf: url, encoding: .utf8)
            else {
                licenseText = "同梱のライセンス文書を読み込めませんでした。ソースコードのLICENSEを確認してください。"
                return
            }
            licenseText = contents
        }
    }
}
