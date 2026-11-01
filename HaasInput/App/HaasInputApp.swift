import AppKit
import SwiftUI

@main
struct HaasInputApp: App {
    @NSApplicationDelegateAdaptor(HaasApplicationDelegate.self) private var appDelegate
    @StateObject private var app: HaasAppModel

    init() {
        HaasAppConfiguration.prepare()
        _app = StateObject(wrappedValue: HaasAppModel())
    }

    var body: some Scene {
        WindowGroup(HaasAppConfiguration.name, id: HaasAppConfiguration.mainWindowID) {
            HaasRootView(app: app)
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .onAppear { appDelegate.appModel = app }
        }
        .defaultSize(width: 880, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("Haas音声入力について") { app.showAbout() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("設定…") { app.show(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra(HaasAppConfiguration.name, systemImage: "waveform") {
            HaasMenuBarView(app: app)
                .environment(\.locale, Locale(identifier: "ja_JP"))
        }
        .menuBarExtraStyle(.menu)
    }
}
