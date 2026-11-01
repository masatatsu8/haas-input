import AppKit
import Carbon
import Foundation
import os

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
