import Foundation

@MainActor
protocol HaasInputTargetChecking {
    var diagnosticAppIdentifier: String { get }
    func rejectionReason() -> String?
    /// 入力欄のカーソル直前の文字列と選択範囲。読めなければ .unreadable
    func fieldState() -> HaasFieldState
    /// 入力先のアプリを前面に出す。出せなければ false
    func activate() -> Bool
}

extension HaasInputTargetChecking {
    func fieldState() -> HaasFieldState { .unreadable }
    func activate() -> Bool { false }
}

@MainActor
protocol HaasTextPasting {
    func paste(_ text: String, shouldPaste: @escaping () -> Bool) async -> CursorPaster.PasteOutcome
    func copy(_ text: String) -> Bool
}

@MainActor
struct HaasSystemTextPaster: HaasTextPasting {
    func paste(_ text: String, shouldPaste: @escaping () -> Bool) async -> CursorPaster.PasteOutcome {
        await CursorPaster.startPasteAtCursor(text, shouldPaste: shouldPaste).value
    }

    func copy(_ text: String) -> Bool {
        ClipboardManager.setClipboard(text)
    }
}
