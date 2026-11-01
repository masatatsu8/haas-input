import AppKit
import XCTest
@testable import VoiceInk

@MainActor
final class CursorPasterClipboardTests: XCTestCase {
    private enum ClipboardChange: Equatable { case differentText, sameText, replayedContents, none }

    func testChangedClipboardIsRejectedWithoutOverwritingNewerCopies() async throws {
        let fixture = try ClipboardFixture()
        let defaults = UserDefaults.standard
        let preferenceKey = "clipboardRestoreDelay"
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let oldDelay = defaults.persistentDomain(forName: domain)?[preferenceKey]
        defaults.set(0.25, forKey: preferenceKey)
        defer {
            if let oldDelay { defaults.set(oldDelay, forKey: preferenceKey) }
            else { defaults.removeObject(forKey: preferenceKey) }
            fixture.restoreOriginalIfStillOwned()
        }

        for change in [ClipboardChange.differentText, .sameText, .replayedContents, .none] {
            let previousText = "Before paste \(UUID().uuidString)"
            let expectedText = "Haas segment \(UUID().uuidString)"
            try fixture.write(previousText)
            let beforePreparation = fixture.pasteboard.changeCount
            let ownerBeforePreparation = fixture.token
            let task = CursorPaster.startPasteAtCursor(expectedText, shouldPaste: {
                // Any clipboard preparation invalidates admission, so no key event can be sent.
                fixture.pasteboard.changeCount == beforePreparation
                    && fixture.pasteboard.string(forType: .string) == previousText
                    && fixture.pasteboard.string(forType: ClipboardManager.pasteSessionType) == ownerBeforePreparation
            })
            guard await waitForClipboard(expectedText, on: fixture.pasteboard) else {
                _ = await task.value
                await drainPasteQueue()
                XCTFail("The production queue did not prepare its clipboard")
                return
            }
            let pasteToken = try XCTUnwrap(fixture.pasteboard.string(forType: ClipboardManager.pasteSessionType))
            try fixture.adopt(text: expectedText, token: pasteToken)

            let resultingText: String
            let resultingToken: String
            switch change {
            case .differentText:
                resultingText = "A newer copy \(UUID().uuidString)"
                resultingToken = fixture.token
                try fixture.write(resultingText)
            case .sameText:
                resultingText = expectedText
                resultingToken = fixture.token
                try fixture.write(resultingText)
            case .replayedContents:
                resultingText = expectedText
                resultingToken = pasteToken
                try fixture.replayCurrentContents()
            case .none:
                resultingText = previousText
                resultingToken = fixture.token
            }

            let result = await task.value
            XCTAssertEqual(result.result, change == .none ? .commandNotPosted : .clipboardChanged)
            await drainPasteQueue()
            XCTAssertTrue(fixture.pasteboard.string(forType: .string) == resultingText,
                          "Owned clipboard contents changed unexpectedly")
            try fixture.adopt(text: resultingText, token: resultingToken)
        }
    }

    private func waitForClipboard(_ text: String, on pasteboard: NSPasteboard) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if pasteboard.string(forType: .string) == text { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func drainPasteQueue() async {
        _ = await CursorPaster.startPasteAtCursor("", shouldPaste: { false }).value
    }
}

@MainActor
private final class ClipboardFixture {
    enum Interference: Error { case clipboardChanged }

    let pasteboard = NSPasteboard.general
    let token = "HaasClipboardFixture-\(UUID().uuidString)"
    private let originalItems: [NSPasteboardItem]
    private var changeCount: Int
    private var text: String?
    private var ownerToken: String?
    private var hasWritten = false

    init() throws {
        guard Bundle.main.bundleIdentifier == "com.tatsumi.VoiceInkHaas.TestsHost" else {
            throw CocoaError(.fileReadNoPermission)
        }
        changeCount = pasteboard.changeCount
        originalItems = Self.copyItems(from: pasteboard)
        guard pasteboard.changeCount == changeCount else { throw Interference.clipboardChanged }
    }

    var isStillOwned: Bool {
        guard pasteboard.changeCount == changeCount else { return false }
        guard hasWritten else { return true }
        return pasteboard.string(forType: .string) == text
            && pasteboard.string(forType: ClipboardManager.pasteSessionType) == ownerToken
            && pasteboard.changeCount == changeCount
    }

    func write(_ text: String) throws {
        guard isStillOwned else { throw Interference.clipboardChanged }
        guard ClipboardManager.setClipboard(text, transient: true, sessionID: token) else {
            throw Interference.clipboardChanged
        }
        try adopt(text: text, token: token)
    }

    func replayCurrentContents() throws {
        guard isStillOwned, let text, let ownerToken else { throw Interference.clipboardChanged }
        let contents = Self.copyItems(from: pasteboard)
        guard isStillOwned else { throw Interference.clipboardChanged }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(contents) else { throw Interference.clipboardChanged }
        try adopt(text: text, token: ownerToken)
    }

    func adopt(text: String, token: String) throws {
        let count = pasteboard.changeCount
        guard pasteboard.string(forType: .string) == text,
            pasteboard.string(forType: ClipboardManager.pasteSessionType) == token,
            pasteboard.changeCount == count
        else { throw Interference.clipboardChanged }
        self.text = text
        ownerToken = token
        changeCount = count
        hasWritten = true
    }

    func restoreOriginalIfStillOwned() {
        guard hasWritten, isStillOwned else { return }
        pasteboard.clearContents()
        if !originalItems.isEmpty { _ = pasteboard.writeObjects(originalItems) }
    }

    private static func copyItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }
}
