import AppKit

@MainActor
final class HaasApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var appModel: HaasAppModel?
    private var isPreparingTermination = false

    func applicationWillTerminate(_ notification: Notification) {
        appModel?.shortcuts?.stopMonitoring()
        appModel?.presentation?.hide()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        appModel?.show(appModel?.selectedDestination ?? .home)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine = appModel?.engine else { return .terminateNow }
        guard !isPreparingTermination else { return .terminateLater }
        isPreparingTermination = true
        Task { @MainActor in
            let canTerminate = await engine.prepareForTermination()
            isPreparingTermination = false
            if !canTerminate {
                let alert = NSAlert()
                alert.messageText = "保存できていない認識結果があります"
                alert.informativeText = "入力確認待ちの文章をコピーし、保存先を確認してから、もう一度終了してください。"
                alert.addButton(withTitle: "アプリに戻る")
                alert.runModal()
                appModel?.show(.home)
            }
            sender.reply(toApplicationShouldTerminate: canTerminate)
        }
        return .terminateLater
    }
}
