import AppKit
import SwiftUI

@MainActor
struct HaasMenuBarView: View {
    @ObservedObject var app: HaasAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let engine = app.engine {
                HaasRecordingMenu(engine: engine)
                Divider()
            }
            Button("ウインドウを開く") { show(.home) }
            Button("履歴を開く") { show(.history) }
            Button("辞書を開く") { show(.dictionary) }
            Button("設定…") { show(.settings) }
            Divider()
            Button("Haas音声入力を終了") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func show(_ destination: HaasDestination) {
        app.selectedDestination = destination
        openWindow(id: HaasAppConfiguration.mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private struct HaasRecordingMenu: View {
    @ObservedObject var engine: HaasEngine

    var body: some View {
        Text(engine.recordingState.displayName)
        switch engine.recordingState {
        case .idle:
            Button("録音を開始") { Task { await engine.toggleRecording() } }
        case .recording:
            Button("録音を終了") { Task { await engine.toggleRecording() } }
            Button("録音を取り消す") { Task { await engine.cancelRecording() } }
        case .starting:
            Button("録音の準備を取り消す") { Task { await engine.cancelRecording() } }
        case .transcribing, .busy:
            Button("処理を取り消す") { Task { await engine.cancelRecording() } }
        }
        Button("直前の認識結果をコピー") { engine.copyLastTranscription() }
    }
}
