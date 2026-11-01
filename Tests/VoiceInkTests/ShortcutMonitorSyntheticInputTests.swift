import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest
import os
@testable import VoiceInk

@MainActor
final class ShortcutMonitorSyntheticInputTests: XCTestCase {
    func testHeldRightShiftIgnoresOwnPasteAndReleasesOnlyOnExternalKeyUp() async throws {
        let currentPID = Int64(ProcessInfo.processInfo.processIdentifier)
        for externalPID in [Int64(0), currentPID + 100_000] {
            let tapBox = OSAllocatedUnfairLock<TestShortcutEventTap?>(initialState: nil)
            let monitor = ShortcutMonitor(
                owner: "synthetic-input-regression",
                makeEventTap: { _, handler in
                    let tap = TestShortcutEventTap(handler: handler)
                    tapBox.withLock { $0 = tap }
                    return tap
                },
                isKeyDown: { _ in true },
                isShortcutPressed: { _ in true },
                allowsInput: { true },
                allowsDispatch: { true },
                workspaceNotificationCenter: NotificationCenter()
            )
            defer { monitor.stop() }

            let down = expectation(description: "Right Shift down from source \(externalPID)")
            let prematureUp = expectation(description: "Own Cmd+V must not release Right Shift")
            prematureUp.isInverted = true
            let released = expectation(description: "Actual Right Shift release from source \(externalPID)")
            var isPhysicalReleasePhase = false
            var transitions: [String] = []
            var releaseTimes: [TimeInterval] = []
            XCTAssertTrue(monitor.start(
                shortcuts: [.primaryRecording: .modifierOnly(
                    keyCode: UInt16(kVK_RightShift), modifierFlags: .shift
                )],
                interruptibleActions: [.primaryRecording],
                onShortcutDown: { _, _ in
                    transitions.append("down")
                    down.fulfill()
                },
                onShortcutUp: { _, eventTime in
                    transitions.append("up")
                    releaseTimes.append(eventTime)
                    if isPhysicalReleasePhase { released.fulfill() }
                    else { prematureUp.fulfill() }
                }
            ))
            let tap = try XCTUnwrap(tapBox.withLock { $0 })
            let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
            let start = ProcessInfo.processInfo.systemUptime

            let shiftDown = try keyboardEvent(source: source, key: UInt16(kVK_RightShift), down: true,
                                             flags: CGEventFlags(rawValue: 0x20104), time: start)
            shiftDown.setIntegerValueField(.eventSourceUnixProcessID, value: externalPID)
            XCTAssertFalse(tap.deliver(shiftDown))
            await fulfillment(of: [down], timeout: 1)
            XCTAssertEqual(transitions, ["down"])

            let pasteKeys: [(UInt16, Bool, CGEventFlags)] = [
                (UInt16(kVK_Command), true, .maskCommand),
                (UInt16(kVK_ANSI_V), true, .maskCommand),
                (UInt16(kVK_ANSI_V), false, .maskCommand),
                (UInt16(kVK_Command), false, []),
            ]
            for (index, key) in pasteKeys.enumerated() {
                let event = try keyboardEvent(
                    source: source, key: key.0, down: key.1, flags: key.2,
                    time: start + 2 + Double(index) * 0.01
                )
                XCTAssertEqual(event.getIntegerValueField(.eventSourceUnixProcessID), currentPID)
                XCTAssertFalse(tap.deliver(event), "Own paste events must pass through to the destination")
            }
            await fulfillment(of: [prematureUp], timeout: 0.15)
            XCTAssertEqual(transitions, ["down"], "Pasting must not finish a held recording")

            isPhysicalReleasePhase = true
            let shiftUp = try keyboardEvent(source: source, key: UInt16(kVK_RightShift), down: false,
                                           flags: [], time: start + 3)
            shiftUp.setIntegerValueField(.eventSourceUnixProcessID, value: externalPID)
            XCTAssertFalse(tap.deliver(shiftUp))
            await fulfillment(of: [released], timeout: 1)
            XCTAssertEqual(transitions, ["down", "up"])
            XCTAssertEqual(releaseTimes.count, 1)
            if let releaseTime = releaseTimes.first {
                XCTAssertEqual(releaseTime, start + 3, accuracy: 0.000_001)
            }
        }
    }

    private func keyboardEvent(
        source: CGEventSource, key: UInt16, down: Bool, flags: CGEventFlags, time: TimeInterval
    ) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down))
        event.flags = flags
        event.timestamp = UInt64(time * 1_000_000_000)
        return event
    }
}

private final class TestShortcutEventTap: ShortcutEventTap, @unchecked Sendable {
    var isValid = true
    var isEnabled = true
    private let handler: @Sendable (CGEventType, CGEvent) -> Bool

    init(handler: @escaping @Sendable (CGEventType, CGEvent) -> Bool) {
        self.handler = handler
    }

    func deliver(_ event: CGEvent) -> Bool {
        ShortcutEventTapThread.shared.performAndWait { self.handler(event.type, event) }
    }

    func enable() { isEnabled = true }
    func stop() { isEnabled = false; isValid = false }
}
