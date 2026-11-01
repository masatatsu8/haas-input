import Foundation

@MainActor
protocol HaasInputTargetChecking {
    var diagnosticAppIdentifier: String { get }
    func rejectionReason() -> String?
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
