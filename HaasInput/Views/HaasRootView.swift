import AppKit
import SwiftData
import SwiftUI

@MainActor
struct HaasRootView: View {
    @ObservedObject var app: HaasAppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let persistence = app.persistence, let engine = app.engine,
                let shortcuts = app.shortcuts, let presentation = app.presentation {
                HaasMainView(app: app, engine: engine, shortcuts: shortcuts, presentation: presentation)
                    .modelContainer(persistence.container)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    Label("保存済みデータを開けません", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.title2.bold())
                    Text(app.startupError ?? "起動を完了できませんでした。")
                        .textSelection(.enabled)
                    Button("保存先を開く") { HaasStorageLocation.open() }
                    Text("データを削除したり、新しい空の履歴に置き換えたりせずに停止しています。")
                        .foregroundStyle(.secondary)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear {
            app.openMainWindow = { openWindow(id: HaasAppConfiguration.mainWindowID) }
            app.refreshPermissions()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.refreshPermissions() }
        }
    }
}

@MainActor
private struct HaasMainView: View {
    @ObservedObject var app: HaasAppModel
    @ObservedObject var engine: HaasEngine
    @ObservedObject var shortcuts: RecordingShortcutManager
    @ObservedObject var presentation: HaasRecorderPresentation

    var body: some View {
        NavigationSplitView {
            List(HaasDestination.allCases, selection: Binding<HaasDestination?>(
                get: { app.selectedDestination },
                set: { if let destination = $0 { app.selectedDestination = destination } }
            )) { destination in
                Label(destination.title, systemImage: destination.symbol)
                    .tag(destination)
                    .accessibilityIdentifier("haasNavigation_\(destination.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 175, max: 220)
            .navigationTitle(HaasAppConfiguration.name)
        } detail: {
            Group {
                switch app.selectedDestination {
                case .home:
                    HaasHomeView(app: app, engine: engine, shortcuts: shortcuts)
                case .usage:
                    if let recorder = app.usageRecorder { HaasUsageView(recorder: recorder) }
                case .history:
                    HaasHistoryView(selectedID: $app.selectedHistoryID, activeAudioURL: engine.activeAudioURL)
                case .dictionary:
                    HaasDictionaryView()
                case .settings:
                    HaasSettingsView(app: app, engine: engine, shortcuts: shortcuts, presentation: presentation)
                }
            }
            .navigationTitle(app.selectedDestination.title)
        }
    }
}

enum HaasStorageLocation {
    @MainActor static func open() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppStorageIdentity.applicationSupportDirectoryName, isDirectory: true)
        NSWorkspace.shared.open(url)
    }
}
