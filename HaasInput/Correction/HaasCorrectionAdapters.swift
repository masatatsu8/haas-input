import AppKit
import Foundation

/// 前の文を消して直した文を貼る役と、クリップボードへコピーする役
@MainActor
protocol HaasCorrectionReplacing {
    func replace(
        _ text: String, deleteCount: Int, shouldContinue: @escaping (_ deleted: Int) async -> Bool,
        pasteGuard: @escaping () -> Bool
    ) async -> HaasReplaceOutcome
    func copy(_ text: String) -> Bool
}

/// 本番の置き換え役。既存の貼り付けと同じ列に並べる
@MainActor
struct HaasSystemCorrectionReplacer: HaasCorrectionReplacing {
    func replace(
        _ text: String, deleteCount: Int, shouldContinue: @escaping (_ deleted: Int) async -> Bool,
        pasteGuard: @escaping () -> Bool
    ) async -> HaasReplaceOutcome {
        await CursorPaster.startReplaceAtCursor(
            text, deleteCount: deleteCount, shouldContinue: shouldContinue, pasteGuard: pasteGuard
        ).value
    }

    func copy(_ text: String) -> Bool {
        ClipboardManager.setClipboard(text)
    }
}

/// 入力欄を確かめられないときの戻り先。前面に戻すだけで、置き換えの入力先には決してしない
@MainActor
struct HaasFrontmostApplicationTarget: HaasInputTargetChecking {
    let application: NSRunningApplication

    var diagnosticAppIdentifier: String { application.bundleIdentifier ?? "unknown" }

    func rejectionReason() -> String? { "return_target_only" }

    func activate() -> Bool { application.activate() }
}
