import AppKit
import SwiftUI

/// ポップアップの開閉の状態。開いている間と確定中は、ホットキーでもう一度 begin を呼ばせない。
/// 閉じる処理 (確定か取り消し) は、1回の閉じ方につき1つだけ走る
struct HaasCorrectionSessionGate {
    private enum State { case idle, open, closing }
    private var state = State.idle

    /// 新しく開いてよければ true。開いている間と確定中は false
    mutating func tryOpen() -> Bool {
        guard state == .idle else { return false }
        state = .open
        return true
    }

    /// 開いている状態からの閉じる処理を始める。すでに閉じ始めていれば false
    mutating func beginClose() -> Bool {
        guard state == .open else { return false }
        state = .closing
        return true
    }

    /// 確定の完了後、または取り消しの後
    mutating func finish() {
        state = .idle
    }

    var isOpen: Bool { state == .open }
}

/// ポップアップの状態。直す文と、辞書の候補、その選択を持つ
@MainActor
final class HaasCorrectionPanelModel: ObservableObject {
    let draft: HaasCorrectionDraft
    private let suggest: (String) -> HaasSuggestionResult

    @Published var corrected: String {
        didSet {
            guard corrected != oldValue else { return }
            rebuildSuggestions()
        }
    }
    @Published private(set) var suggestions: [HaasDictionarySuggestion] = []
    @Published var selectedIDs: Set<Int> = []
    @Published private(set) var notice: String?

    init(draft: HaasCorrectionDraft, suggest: @escaping (String) -> HaasSuggestionResult) {
        self.draft = draft
        self.suggest = suggest
        corrected = draft.originalText
        apply(suggest(draft.originalText), previous: [], previousSelectedIDs: [])
    }

    var primaryButtonTitle: String {
        switch draft.decision {
        case .replaceAutomatically: return "直して入力"
        case let .replaceAfterConfirmation(deleteCount): return "前の\(deleteCount)文字を消して入れ直す"
        case .copyOnly: return "直してコピー"
        }
    }

    var canConfirm: Bool {
        !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 選ばれている候補だけ。登録はこれだけにする
    var selectedSuggestions: [HaasDictionarySuggestion] {
        suggestions.filter { selectedIDs.contains($0.id) }
    }

    func setReading(_ reading: String, for id: Int) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
        suggestions[index].reading = reading
    }

    private func rebuildSuggestions() {
        apply(suggest(corrected), previous: suggestions, previousSelectedIDs: selectedIDs)
    }

    /// 候補を作り直す。前の選択と読みの修正は、同じ before と writtenForm の候補にだけ引き継ぐ
    private func apply(
        _ result: HaasSuggestionResult, previous: [HaasDictionarySuggestion], previousSelectedIDs: Set<Int>
    ) {
        func sameKey(_ a: HaasDictionarySuggestion, _ b: HaasDictionarySuggestion) -> Bool {
            a.before == b.before && a.writtenForm == b.writtenForm
        }
        var rebuilt = result.suggestions
        var selected = Set<Int>()
        for index in rebuilt.indices {
            guard let old = previous.first(where: { sameKey($0, rebuilt[index]) }) else { continue }
            if previousSelectedIDs.contains(old.id) { selected.insert(rebuilt[index].id) }
            if rebuilt[index].kind != .replacement { rebuilt[index].reading = old.reading }
        }
        suggestions = rebuilt
        selectedIDs = selected
        if result.usedDictionaryForms.isEmpty {
            notice = nil
        } else {
            let forms = result.usedDictionaryForms.map { "『\($0)』" }.joined(separator: "、")
            notice = "辞書の\(forms)が使われています。辞書の画面で見直せます"
        }
    }
}

/// 直す文を入れる欄。NSTextView なので日本語入力の変換が使える
private struct HaasCorrectionTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        // 窓が key になった後で入力欄にする
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // 変換中の文字を壊さない
        if textView.string != text, !textView.hasMarkedText() { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if text.wrappedValue != textView.string { text.wrappedValue = textView.string }
        }
    }
}

private struct HaasCorrectionPanelView: View {
    @ObservedObject var model: HaasCorrectionPanelModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HaasCorrectionTextEditor(text: $model.corrected)
                .frame(minHeight: 110)

            if !model.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("辞書に登録する候補").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.suggestions) { suggestion in
                        suggestionRow(suggestion)
                    }
                }
            }

            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("取り消し", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(model.primaryButtonTitle, action: onConfirm)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canConfirm)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func suggestionRow(_ suggestion: HaasDictionarySuggestion) -> some View {
        HStack(spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { model.selectedIDs.contains(suggestion.id) },
                    set: { isOn in
                        if isOn { model.selectedIDs.insert(suggestion.id) } else { model.selectedIDs.remove(suggestion.id) }
                    })
            )
            .labelsHidden()
            Text(suggestion.writtenForm).lineLimit(1)
            if suggestion.kind != .replacement {
                TextField(
                    "読み",
                    text: Binding(
                        get: { suggestion.reading },
                        set: { model.setReading($0, for: suggestion.id) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
            }
            Spacer()
            Text(kindLabel(suggestion.kind)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func kindLabel(_ kind: HaasDictionarySuggestion.Kind) -> String {
        switch kind {
        case .newWord: return "辞書の語"
        case .addReading: return "読みを追加"
        case .replacement: return "置き換え"
        }
    }
}

/// 通常の key になる窓。日本語入力の変換を使うため nonactivatingPanel にしない
private final class HaasCorrectionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect, styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        title = "直前の入力を直す"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        level = .floating
    }
}

/// ホットキーで出す訂正のポップアップ。begin の後に開き、閉じた後に confirm か cancel を1度だけ呼ぶ
@MainActor
final class HaasCorrectionPanelController: NSObject, NSWindowDelegate {
    private let coordinator: HaasCorrectionCoordinator
    private let notify: @MainActor (_ message: String, _ type: AppNotificationView.NotificationType) -> Void
    private var gate = HaasCorrectionSessionGate()
    private var window: HaasCorrectionWindow?
    private var model: HaasCorrectionPanelModel?

    init(
        coordinator: HaasCorrectionCoordinator,
        notify: @escaping @MainActor (_ message: String, _ type: AppNotificationView.NotificationType) -> Void = {
            message, type in
            NotificationManager.shared.showNotification(title: message, type: type)
        }
    ) {
        self.coordinator = coordinator
        self.notify = notify
    }

    func show() {
        // 開いている間と確定中は begin を呼ばない。開いていれば前面に出すだけにする
        guard gate.tryOpen() else {
            if gate.isOpen, let window {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
        // 入力先と判定を記録するため、自分の窓を出す前に begin を呼ぶ
        guard let draft = coordinator.begin() else {
            gate.finish()
            notify("直す入力がありません", .info)
            return
        }
        let model = HaasCorrectionPanelModel(draft: draft) { [coordinator] in coordinator.suggestions(for: $0) }
        self.model = model
        let view = HaasCorrectionPanelView(
            model: model, onConfirm: { [weak self] in self?.confirm() }, onCancel: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view)
        let window = HaasCorrectionWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize))
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.delegate = self
        position(window)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 取り消し。窓を閉じてから coordinator.cancel() を呼ぶ
    func close() {
        guard gate.beginClose() else { return }
        dismissWindow()
        coordinator.cancel()
        gate.finish()
    }

    func windowWillClose(_ notification: Notification) {
        // 閉じるボタンなど、窓の側から閉じられたとき
        close()
    }

    private func confirm() {
        guard gate.beginClose(), let model else { return }
        let draft = model.draft
        let corrected = model.corrected
        let register = model.selectedSuggestions
        dismissWindow()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.coordinator.confirm(draft, corrected: corrected, register: register)
            self.gate.finish()
            self.report(outcome)
        }
    }

    private func report(_ outcome: HaasCorrectionOutcome) {
        switch outcome.result {
        case let .copied(message): notify(message, .info)
        case let .failed(message): notify(message, .error)
        case .unchanged, .replaced: break
        }
        for error in outcome.dictionaryErrors { notify("辞書に登録できませんでした: \(error)", .error) }
        if let historyError = outcome.historyError { notify(historyError, .error) }
    }

    private func dismissWindow() {
        let closing = window
        window = nil
        model = nil
        closing?.delegate = nil
        closing?.orderOut(nil)
        closing?.close()
    }

    /// 画面の中央、やや上寄り
    private func position(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.62 - size.height / 2)
        window.setFrameOrigin(origin)
    }
}
