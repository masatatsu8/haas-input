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
        let previousPasteTask = pasteQueueTask
        let sessionTask = Task { @MainActor in
            await previousPasteTask?.value
            return await performPasteSession(text, requestedAt: requestedAt, shouldPaste: shouldPaste)
        }
        pasteQueueTask = Task { @MainActor in
            let session = await sessionTask.value
            await session.clipboardRestoreTask?.value
        }
        return Task { @MainActor in
            let session = await sessionTask.value
            return session.outcome
        }
    }

    /// 末尾の deleteCount 文字を Backspace で消してから text を貼る。既存の貼り付けと同じ列に並べる
    /// - shouldContinue: Backspace の前ごと (deleted は消した数) と貼り付けの直前に呼ぶ。入力欄の中身の確認はここで行う
    /// - pasteGuard: 貼り付け (⌘V の前・途中・後) だけで使う。貼ると中身が変わるため入力欄の中身は見ない
    @MainActor
    @discardableResult
    static func startReplaceAtCursor(
        _ text: String, deleteCount: Int,
        shouldContinue: @escaping (_ deleted: Int) -> Bool,
        pasteGuard: @escaping () -> Bool
    ) -> Task<HaasReplaceOutcome, Never> {
        let previousPasteTask = pasteQueueTask
        let sessionTask = Task { @MainActor in
            await previousPasteTask?.value
            return await performReplaceSession(
                text, deleteCount: deleteCount, shouldContinue: shouldContinue, pasteGuard: pasteGuard)
        }
        pasteQueueTask = Task { @MainActor in
            let session = await sessionTask.value
            await session.clipboardRestoreTask?.value
        }
        return Task { @MainActor in
            await sessionTask.value.outcome
        }
    }

    @MainActor
    private static func performReplaceSession(
        _ text: String, deleteCount: Int,
        shouldContinue: @escaping (_ deleted: Int) -> Bool,
        pasteGuard: @escaping () -> Bool
    ) async -> (outcome: HaasReplaceOutcome, clipboardRestoreTask: Task<Void, Never>?) {
        let sessionID = UUID().uuidString
        let pasteboard = NSPasteboard.general
        // 削除より前に、元のクリップボードを保存して貼る文を準備する
        let savedContents = snapshotClipboard(from: pasteboard)
        guard ClipboardManager.setClipboard(text, transient: true, sessionID: sessionID) else {
            logger.error("Failed to prepare clipboard for replacement id=\(sessionID, privacy: .public)")
            return (.notStarted, nil)
        }
        let preparedClipboardChangeCount = pasteboard.changeCount
        let ownsClipboard: () -> Bool = {
            pasteboardStillOwnedByPasteSession(
                pasteboard, expectedText: text, sessionID: sessionID,
                expectedChangeCount: preparedClipboardChangeCount)
        }
        await wait(prePasteDelay)

        let pasteRejection: () -> PasteResult? = {
            guard ownsClipboard() else { return .clipboardChanged }
            return pasteGuard() ? nil : .commandNotPosted
        }
        let outcome = await runReplacement(
            deleteCount: deleteCount,
            // Backspace の前ごとに、クリップボードがこのセッションのままかも確かめる
            shouldContinue: { deleted in ownsClipboard() && shouldContinue(deleted) },
            postBackspace: { await postBackspace() },
            paste: { await pasteFromClipboard(sessionID: sessionID, pasteRejection: pasteRejection) }
        )
        logger.notice("Replace id=\(sessionID, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)")
        let restore = scheduleClipboardRestore(
            savedContents, expectedText: text, sessionID: sessionID,
            expectedChangeCount: preparedClipboardChangeCount, on: pasteboard
        )
        return (outcome, restore)
    }

    /// 消す手順の本体。Backspace の前ごと、貼り付けの直前に shouldContinue で止められる。貼り付けの後は確認しない
    static func runReplacement(
        deleteCount: Int,
        shouldContinue: (_ deleted: Int) -> Bool,
        postBackspace: () async -> Bool,
        paste: () async -> PasteResult
    ) async -> HaasReplaceOutcome {
        var deleted = 0
        while deleted < deleteCount {
            guard shouldContinue(deleted) else {
                return deleted == 0 ? .notStarted : .deletionInterrupted(deleted: deleted)
            }
            guard await postBackspace() else { return .deletionInterrupted(deleted: deleted) }
            deleted += 1
        }
        guard shouldContinue(deleted) else {
            return deleted == 0 ? .notStarted : .deletionInterrupted(deleted: deleted)
        }
        return await paste() == .commandPosted ? .completed : .pasteUncertain
    }

    /// Backspace (keyCode 0x33) を1回送る。印を付けて、利用者の操作と区別できるようにする
    @MainActor
    private static func postBackspace() async -> Bool {
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
        await wait(pasteShortcutEventDelay)
        up.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        return true
    }

    @MainActor
    private static func performPasteSession(
        _ text: String, requestedAt: TimeInterval, shouldPaste: @escaping () -> Bool
    ) async -> (outcome: PasteOutcome, clipboardRestoreTask: Task<Void, Never>?) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let queueWaitMs = elapsedMilliseconds(since: requestedAt)
        let sessionID = UUID().uuidString
        guard shouldPaste() else { return (PasteOutcome(result: .commandNotPosted), nil) }
        let pasteboard = NSPasteboard.general
        let savedContents = snapshotClipboard(from: pasteboard)
        guard ClipboardManager.setClipboard(text, transient: true, sessionID: sessionID) else {
            logger.error("Failed to prepare clipboard for paste id=\(sessionID, privacy: .public)")
            return (PasteOutcome(result: .commandNotPosted), nil)
        }
        let preparedClipboardChangeCount = pasteboard.changeCount
        await wait(prePasteDelay)

        let pasteRejection: () -> PasteResult? = {
            guard pasteboardStillOwnedByPasteSession(
                pasteboard, expectedText: text, sessionID: sessionID,
                expectedChangeCount: preparedClipboardChangeCount
            ) else { return .clipboardChanged }
            return shouldPaste() ? nil : .commandNotPosted
        }
        let appIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        let result: PasteResult
        if let rejection = pasteRejection() {
            logger.notice("Paste guard id=\(sessionID, privacy: .public) phase=after-preparation reason=\(String(describing: rejection), privacy: .public)")
            result = rejection
        } else {
            result = await pasteFromClipboard(sessionID: sessionID, pasteRejection: pasteRejection)
        }
        logger.notice("Paste id=\(sessionID, privacy: .public) app=\(appIdentifier, privacy: .public) commandPosted=\(result.didPostPasteCommand, privacy: .public) queueMs=\(queueWaitMs, privacy: .public) elapsedMs=\(elapsedMilliseconds(since: startedAt), privacy: .public)")
        let restore = scheduleClipboardRestore(
            savedContents, expectedText: text, sessionID: sessionID,
            expectedChangeCount: preparedClipboardChangeCount, on: pasteboard
        )
        return (PasteOutcome(result: result), restore)
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
    private static func pasteFromClipboard(sessionID: String, pasteRejection: () -> PasteResult?) async -> PasteResult {
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

        if let rejection = pasteRejection() {
            logger.notice("Paste guard id=\(sessionID, privacy: .public) phase=before-command reason=\(String(describing: rejection), privacy: .public)")
            return rejection
        }
        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        if let rejection = pasteRejection() {
            logger.notice("Paste guard id=\(sessionID, privacy: .public) phase=before-V reason=\(String(describing: rejection), privacy: .public)")
            cmdUp.post(tap: .cghidEventTap)
            return rejection
        }
        vDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vUp.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        cmdUp.post(tap: .cghidEventTap)

        if let rejection = pasteRejection() {
            logger.notice("Paste guard id=\(sessionID, privacy: .public) phase=after-command reason=\(String(describing: rejection), privacy: .public)")
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
