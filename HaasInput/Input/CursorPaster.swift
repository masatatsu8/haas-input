import AppKit
import Carbon
import Foundation
import os

/// 前の文を消して貼り直した結果
enum HaasReplaceOutcome: Equatable {
    /// 何も消さずに止めた
    case notStarted
    /// 途中で止めた (消した文字数)。貼り付けはしていない
    case deletionInterrupted(deleted: Int)
    /// 消した後の貼り付けが完了したか確かめられない
    case pasteUncertain
    case completed
}

final class CursorPaster {
    private typealias ClipboardItemSnapshot = [(NSPasteboard.PasteboardType, Data)]
    private typealias ClipboardSnapshot = [ClipboardItemSnapshot]
    private static let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "CursorPaster")

    enum PasteResult: Equatable {
        case commandPosted
        case commandNotPosted
        case commandPartiallyPosted
        case clipboardChanged

        var didPostPasteCommand: Bool { self == .commandPosted }
    }

    struct PasteOutcome {
        let result: PasteResult
    }

    private static let prePasteDelay: TimeInterval = 0.20
    private static let pasteShortcutEventDelay: TimeInterval = 0.01
    private static let minimumClipboardRestoreDelay: TimeInterval = 0.25
    @MainActor private static var pasteQueueTask: Task<Void, Never>?

    @MainActor
    @discardableResult
    static func startPasteAtCursor(
        _ text: String, shouldPaste: @escaping () -> Bool
    ) -> Task<PasteOutcome, Never> {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        return enqueueSession {
            await performPasteSession(text, requestedAt: requestedAt, shouldPaste: shouldPaste)
        }
    }

    /// 貼り付けの列に1件並べ、前の件とクリップボードの復元が終わってから始める
    @MainActor
    private static func enqueueSession<Outcome>(
        _ session: @escaping @MainActor () async -> (outcome: Outcome, clipboardRestoreTask: Task<Void, Never>?)
    ) -> Task<Outcome, Never> {
        let previousPasteTask = pasteQueueTask
        let sessionTask = Task { @MainActor in
            await previousPasteTask?.value
            return await session()
        }
        pasteQueueTask = Task { @MainActor in
            let finished = await sessionTask.value
            await finished.clipboardRestoreTask?.value
        }
        return Task { @MainActor in
            await sessionTask.value.outcome
        }
    }

    /// 貼り付けの確認をする時点。⌘ を押す前、V を押す前、⌘V を送り終えた後
    enum PastePhase: Equatable {
        case beforeCommand, beforeV, afterCommand
    }

    /// 末尾の deleteCount 文字を Backspace で消してから text を貼る。既存の貼り付けと同じ列に並べる
    /// - awaitField: Backspace の前ごと (deleted は消した数) と貼り付けの前に呼ぶ。入力欄の更新が追いつくのを待ってよい
    /// - shouldContinue: awaitField の後に呼ぶ同期の最後の確認。これが true を返してから Backspace の keyDown を
    ///   送るまでは中断点を置かない
    /// - pasteGuard: 貼り付け (⌘ の前・V の前・⌘V の後) で呼ぶ。⌘V の後は貼った分だけ中身が変わる
    /// - modifierFlags: 今押されている修飾キー。最初の Backspace の前に、⌘・⌥・⌃ が離れるのを待つのに使う
    @MainActor
    @discardableResult
    static func startReplaceAtCursor(
        _ text: String, deleteCount: Int,
        awaitField: @escaping @MainActor (_ deleted: Int) async -> Bool,
        shouldContinue: @escaping @MainActor (_ deleted: Int) -> Bool,
        pasteGuard: @escaping @MainActor (PastePhase) -> Bool,
        modifierFlags: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) }
    ) -> Task<HaasReplaceOutcome, Never> {
        enqueueSession {
            await performReplaceSession(
                text, deleteCount: deleteCount, awaitField: awaitField, shouldContinue: shouldContinue,
                pasteGuard: pasteGuard, modifierFlags: modifierFlags)
        }
    }

    @MainActor
    private static func performReplaceSession(
        _ text: String, deleteCount: Int,
        awaitField: @escaping @MainActor (_ deleted: Int) async -> Bool,
        shouldContinue: @escaping @MainActor (_ deleted: Int) -> Bool,
        pasteGuard: @escaping @MainActor (PastePhase) -> Bool,
        modifierFlags: @escaping () -> CGEventFlags
    ) async -> (outcome: HaasReplaceOutcome, clipboardRestoreTask: Task<Void, Never>?) {
        // 削除より前に、元のクリップボードを保存して貼る文を準備する
        guard let clipboard = prepareClipboard(for: text) else { return (.notStarted, nil) }
        let sessionID = clipboard.sessionID
        let ownsClipboard = clipboard.isStillOwned
        await wait(prePasteDelay)

        let pasteRejection: @MainActor (PastePhase) -> PasteResult? = { phase in
            guard ownsClipboard() else { return .clipboardChanged }
            return pasteGuard(phase) ? nil : .commandNotPosted
        }
        let backspace = BackspacePoster()
        let outcome = await runReplacement(
            deleteCount: deleteCount,
            beforeFirstBackspace: { await waitForModifiersReleased(flags: modifierFlags) },
            awaitField: awaitField,
            // Backspace の前ごとに、クリップボードがこのセッションのままかも確かめる
            shouldContinue: { deleted in ownsClipboard() && shouldContinue(deleted) },
            postBackspaceDown: { backspace.postDown() },
            finishBackspace: { await backspace.finish() },
            paste: { await pasteFromClipboard(sessionID: sessionID, pasteRejection: pasteRejection) }
        )
        logger.notice("Replace id=\(sessionID, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)")
        return (outcome, clipboard.scheduleRestore())
    }

    /// 消す手順の本体。Backspace の前ごと、貼り付けの直前に awaitField と shouldContinue で止められる。
    /// 貼り付けの後は確認しない。すべて MainActor の上で動き、shouldContinue が true を返してから
    /// Backspace の keyDown を送るまでの間に中断点はない (その間に利用者の操作やフォーカスの変更を挟まない)
    /// - beforeFirstBackspace: 消す文字があるとき、最初の確認の前に1度だけ呼ぶ。false なら何も消さずに止める
    /// - postBackspaceDown: Backspace の keyDown を同期で送る。送れなければ false
    /// - finishBackspace: keyDown を送った後に、待ってから keyUp を送る
    @MainActor
    static func runReplacement(
        deleteCount: Int,
        beforeFirstBackspace: @MainActor () async -> Bool = { true },
        awaitField: @MainActor (_ deleted: Int) async -> Bool = { _ in true },
        shouldContinue: @MainActor (_ deleted: Int) -> Bool,
        postBackspaceDown: @MainActor () -> Bool,
        finishBackspace: @MainActor () async -> Void = {},
        paste: @MainActor () async -> PasteResult
    ) async -> HaasReplaceOutcome {
        func stopped(_ deleted: Int) -> HaasReplaceOutcome {
            deleted == 0 ? .notStarted : .deletionInterrupted(deleted: deleted)
        }
        // 待つ間に入力欄が変わりうるので、待ってから最初の確認をする
        if deleteCount > 0, !(await beforeFirstBackspace()) { return .notStarted }
        var deleted = 0
        while deleted < deleteCount {
            // 待つのはここまで。最後の確認から keyDown の送信までは await を挟まない
            guard await awaitField(deleted) else { return stopped(deleted) }
            guard shouldContinue(deleted) else { return stopped(deleted) }
            guard postBackspaceDown() else { return .deletionInterrupted(deleted: deleted) }
            deleted += 1
            await finishBackspace()
        }
        guard await awaitField(deleted) else { return stopped(deleted) }
        guard shouldContinue(deleted) else { return stopped(deleted) }
        // 貼り付けは ⌘ を送る直前にも pasteGuard で確かめる
        return await paste() == .commandPosted ? .completed : .pasteUncertain
    }

    /// Backspace と組み合わさると消す範囲が変わる修飾キー (⌘⌫ は行頭まで、⌥⌫ は1語)
    static let backspaceAlteringModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]

    /// ⌘・⌥・⌃ がすべて離れるまで待つ。確定の ⌘↩ の ⌘ が押されたままのことがある。
    /// 期限までに離れなければ false (何も消さない)
    static func waitForModifiersReleased(
        flags: () -> CGEventFlags,
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(20)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if flags().intersection(backspaceAlteringModifiers).isEmpty { return true }
            guard ContinuousClock.now < deadline, !Task.isCancelled else {
                logger.notice("Replace guard phase=before-backspace reason=modifiers-held")
                return false
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Backspace (keyCode 0x33) を送る役。keyDown は同期で送り、keyUp は待ってから送る。
    /// 印を付けて、利用者の操作と区別できるようにする
    @MainActor
    private final class BackspacePoster {
        private var pendingUp: CGEvent?

        func postDown() -> Bool {
            guard AXIsProcessTrusted() else { return false }
            let source = CGEventSource(stateID: .privateState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)
            else { return false }
            for event in [down, up] {
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: HaasSyntheticInput.marker)
            }
            down.post(tap: .cghidEventTap)
            pendingUp = up
            return true
        }

        func finish() async {
            await CursorPaster.wait(CursorPaster.pasteShortcutEventDelay)
            pendingUp?.post(tap: .cghidEventTap)
            pendingUp = nil
            await CursorPaster.wait(CursorPaster.pasteShortcutEventDelay)
        }
    }

    @MainActor
    private static func performPasteSession(
        _ text: String, requestedAt: TimeInterval, shouldPaste: @escaping () -> Bool
    ) async -> (outcome: PasteOutcome, clipboardRestoreTask: Task<Void, Never>?) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let queueWaitMs = elapsedMilliseconds(since: requestedAt)
        guard shouldPaste() else { return (PasteOutcome(result: .commandNotPosted), nil) }
        guard let clipboard = prepareClipboard(for: text) else {
            return (PasteOutcome(result: .commandNotPosted), nil)
        }
        let sessionID = clipboard.sessionID
        await wait(prePasteDelay)

        // 通常の貼り付けは、どの時点でも同じ確認をする
        let pasteRejection: @MainActor (PastePhase) -> PasteResult? = { _ in
            guard clipboard.isStillOwned() else { return .clipboardChanged }
            return shouldPaste() ? nil : .commandNotPosted
        }
        let appIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        let result: PasteResult
        if let rejection = pasteRejection(.beforeCommand) {
            logger.notice("Paste guard id=\(sessionID, privacy: .public) phase=after-preparation reason=\(String(describing: rejection), privacy: .public)")
            result = rejection
        } else {
            result = await pasteFromClipboard(sessionID: sessionID, pasteRejection: pasteRejection)
        }
        logger.notice("Paste id=\(sessionID, privacy: .public) app=\(appIdentifier, privacy: .public) commandPosted=\(result.didPostPasteCommand, privacy: .public) queueMs=\(queueWaitMs, privacy: .public) elapsedMs=\(elapsedMilliseconds(since: startedAt), privacy: .public)")
        return (PasteOutcome(result: result), clipboard.scheduleRestore())
    }

    /// 貼る文を載せたクリップボードの状態。貼り付けと置き換えの両方が同じ規則で準備・確認・復元する
    private struct PreparedClipboard {
        let text: String
        let sessionID: String
        let savedContents: ClipboardSnapshot
        let changeCount: Int
        let pasteboard: NSPasteboard

        /// このセッションが載せた内容のままか
        func isStillOwned() -> Bool {
            CursorPaster.pasteboardStillOwnedByPasteSession(
                pasteboard, expectedText: text, sessionID: sessionID, expectedChangeCount: changeCount)
        }

        @MainActor
        func scheduleRestore() -> Task<Void, Never> {
            CursorPaster.scheduleClipboardRestore(
                savedContents, expectedText: text, sessionID: sessionID,
                expectedChangeCount: changeCount, on: pasteboard)
        }
    }

    /// 元の内容を保存してから text を載せる。載せられなければ nil
    @MainActor
    private static func prepareClipboard(for text: String) -> PreparedClipboard? {
        let sessionID = UUID().uuidString
        let pasteboard = NSPasteboard.general
        let savedContents = snapshotClipboard(from: pasteboard)
        guard ClipboardManager.setClipboard(text, transient: true, sessionID: sessionID) else {
            logger.error("Failed to prepare clipboard for paste id=\(sessionID, privacy: .public)")
            return nil
        }
        return PreparedClipboard(
            text: text, sessionID: sessionID, savedContents: savedContents,
            changeCount: pasteboard.changeCount, pasteboard: pasteboard)
    }

    private static func snapshotClipboard(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        }
    }

    @MainActor
    private static func scheduleClipboardRestore(
        _ savedContents: ClipboardSnapshot,
        expectedText: String,
        sessionID: String,
        expectedChangeCount: Int?,
        on pasteboard: NSPasteboard
    ) -> Task<Void, Never> {
        let delay = min(
            max(
                UserDefaults.standard.double(forKey: "clipboardRestoreDelay"),
                minimumClipboardRestoreDelay
            ),
            5.0
        )
        return Task { @MainActor in
            await wait(delay)
            guard pasteboardStillOwnedByPasteSession(
                pasteboard, expectedText: expectedText, sessionID: sessionID,
                expectedChangeCount: expectedChangeCount
            )
            else {
                logger.notice("Clipboard restore skipped: clipboard changed id=\(sessionID, privacy: .public)")
                return
            }
            pasteboard.clearContents()
            if !savedContents.isEmpty, !pasteboard.writeObjects(pasteboardItems(from: savedContents)) {
                logger.error("Clipboard restore failed id=\(sessionID, privacy: .public)")
                return
            }
            logger.notice("Clipboard restored id=\(sessionID, privacy: .public)")
        }
    }

    private static func pasteboardStillOwnedByPasteSession(
        _ pasteboard: NSPasteboard,
        expectedText: String,
        sessionID: String,
        expectedChangeCount: Int?
    ) -> Bool {
        if let expectedChangeCount, pasteboard.changeCount != expectedChangeCount { return false }
        guard pasteboard.string(forType: .string) == expectedText,
            pasteboard.string(forType: ClipboardManager.pasteSessionType) == sessionID
        else { return false }
        return expectedChangeCount.map { pasteboard.changeCount == $0 } ?? true
    }

    private static func pasteboardItems(from snapshot: ClipboardSnapshot) -> [NSPasteboardItem] {
        snapshot.map { itemSnapshot in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: type)
            }
            return item
        }
    }

    // MARK: - CGEvent paste

    // Posts Cmd+V via CGEvent without modifying the active input source.
    @MainActor
    private static func pasteFromClipboard(
        sessionID: String, pasteRejection: @MainActor (PastePhase) -> PasteResult?
    ) async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events id=\(sessionID, privacy: .public)")
            return .commandNotPosted
        }

        let source = CGEventSource(stateID: .privateState)

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else {
            logger.error("Failed to create Cmd+V keyboard events id=\(sessionID, privacy: .public)")
            return .commandNotPosted
        }

        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdUp.flags = []
        // 利用者の操作と区別できるよう、自分が送るイベントに印を付ける
        for event in [cmdDown, vDown, vUp, cmdUp] {
            event.setIntegerValueField(.eventSourceUserData, value: HaasSyntheticInput.marker)
        }

        return await runPasteCommand(
            pasteRejection: pasteRejection,
            post: { key in
                switch key {
                case .commandDown: cmdDown.post(tap: .cghidEventTap)
                case .vDown: vDown.post(tap: .cghidEventTap)
                case .vUp: vUp.post(tap: .cghidEventTap)
                case .commandUp: cmdUp.post(tap: .cghidEventTap)
                }
            },
            onRejected: { phase, rejection in
                logger.notice("Paste guard id=\(sessionID, privacy: .public) phase=\(String(describing: phase), privacy: .public) reason=\(String(describing: rejection), privacy: .public)")
            })
    }

    enum PasteKey: Equatable {
        case commandDown, vDown, vUp, commandUp
    }

    /// ⌘V を送る手順。⌘ の前と V の前に確かめ、確認の後は await を挟まずにキーを送る。
    /// V の前に止めたときは ⌘ を離してから返す
    @MainActor
    static func runPasteCommand(
        pasteRejection: @MainActor (PastePhase) -> PasteResult?,
        post: @MainActor (PasteKey) -> Void,
        onRejected: @MainActor (PastePhase, PasteResult) -> Void = { _, _ in }
    ) async -> PasteResult {
        if let rejection = pasteRejection(.beforeCommand) {
            onRejected(.beforeCommand, rejection)
            return rejection
        }
        post(.commandDown)
        await wait(pasteShortcutEventDelay)
        if let rejection = pasteRejection(.beforeV) {
            onRejected(.beforeV, rejection)
            post(.commandUp)
            return rejection
        }
        post(.vDown)
        await wait(pasteShortcutEventDelay)
        post(.vUp)
        await wait(pasteShortcutEventDelay)
        post(.commandUp)

        if let rejection = pasteRejection(.afterCommand) {
            onRejected(.afterCommand, rejection)
            return .commandPartiallyPosted
        }
        return .commandPosted
    }

    private static func elapsedMilliseconds(since start: TimeInterval) -> Int {
        Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

}
