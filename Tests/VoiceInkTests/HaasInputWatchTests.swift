import AppKit
import Carbon.HIToolbox
import XCTest
@testable import VoiceInk

@MainActor
final class HaasInputWatchTests: XCTestCase {
    func testCleanUntilUserTypes() {
        var watch = HaasInputWatch()
        let token = watch.start()
        XCTAssertTrue(watch.isClean(for: token))
        watch.record(.keyDown(keyCode: 0, modifiers: []), isOwnEvent: false, shortcuts: [])
        XCTAssertFalse(watch.isClean(for: token))
    }

    func testOwnEventsAreIgnored() {
        var watch = HaasInputWatch()
        let token = watch.start()
        watch.record(.keyDown(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command]), isOwnEvent: true, shortcuts: [])
        XCTAssertTrue(watch.isClean(for: token))
    }

    func testShortcutKeyIsIgnored() {
        var watch = HaasInputWatch()
        let token = watch.start()
        let shortcut = Shortcut.key(keyCode: 49, modifierFlags: [.option])
        watch.record(.keyDown(keyCode: 49, modifiers: [.option]), isOwnEvent: false, shortcuts: [shortcut])
        XCTAssertTrue(watch.isClean(for: token))
        watch.record(.keyDown(keyCode: 49, modifiers: [.option, .shift]), isOwnEvent: false, shortcuts: [shortcut])
        XCTAssertFalse(watch.isClean(for: token))
    }

    func testShortcutMouseButtonNeedsSameModifiers() {
        let shortcut = Shortcut.mouseButton(buttonNumber: 3, modifierFlags: [.command])
        var watch = HaasInputWatch()
        var token = watch.start()
        watch.record(.mouseDown(button: 3, modifiers: [.command]), isOwnEvent: false, shortcuts: [shortcut])
        XCTAssertTrue(watch.isClean(for: token))
        token = watch.start()
        watch.record(.mouseDown(button: 3, modifiers: []), isOwnEvent: false, shortcuts: [shortcut])
        XCTAssertFalse(watch.isClean(for: token))
    }

    func testMouseScrollAndDragCount() {
        for input in [HaasObservedInput.mouseDown(button: 0, modifiers: []), .scroll, .drag] {
            var watch = HaasInputWatch()
            let token = watch.start()
            watch.record(input, isOwnEvent: false, shortcuts: [])
            XCTAssertFalse(watch.isClean(for: token), "\(input)")
        }
    }

    func testOnlyRecordingAndCorrectionShortcutsAreExcluded() {
        let primary = Shortcut.key(keyCode: 1, modifierFlags: [.option])
        let secondary = Shortcut.mouseButton(buttonNumber: 4)
        let correction = Shortcut.key(keyCode: 2, modifierFlags: [.control])
        XCTAssertEqual(
            HaasUserInputMonitor.excludedShortcuts(primary: primary, secondary: secondary, correction: correction),
            [primary, secondary, correction])
        XCTAssertEqual(
            HaasUserInputMonitor.excludedShortcuts(primary: primary, secondary: nil, correction: nil), [primary])
        XCTAssertEqual(
            HaasUserInputMonitor.excludedShortcuts(primary: nil, secondary: nil, correction: nil), [])
    }

    func testInvalidateAndRestart() {
        var watch = HaasInputWatch()
        let old = watch.start()
        watch.invalidate()
        XCTAssertFalse(watch.isClean(for: old))
        let fresh = watch.start()
        XCTAssertTrue(watch.isClean(for: fresh))
        XCTAssertFalse(watch.isClean(for: old))
        watch.record(.scroll, isOwnEvent: false, shortcuts: [])
        XCTAssertFalse(watch.isClean(for: fresh))
        XCTAssertFalse(watch.isClean(for: old))
    }
}
