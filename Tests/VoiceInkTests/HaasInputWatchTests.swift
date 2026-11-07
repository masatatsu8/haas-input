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

    func testSecondaryShortcutExcludedOnlyWhenInUse() {
        let primary = Shortcut.key(keyCode: 1, modifierFlags: [.option])
        let secondary = Shortcut.key(keyCode: 2, modifierFlags: [.option])
        XCTAssertEqual(
            HaasUserInputMonitor.excludedShortcuts(
                primarySelection: .custom, primary: primary,
                secondarySelection: .none, secondary: secondary, correction: nil),
            [primary])
        XCTAssertEqual(
            HaasUserInputMonitor.excludedShortcuts(
                primarySelection: .custom, primary: primary,
                secondarySelection: .custom, secondary: secondary, correction: nil),
            [primary, secondary])
        // 取消・直前の認識結果・履歴のキーは、除外の一覧を作る入力に含まれない
        let others = [ShortcutAction.cancelRecorder, .pasteLastTranscription, .openQuickHistory]
        XCTAssertFalse(others.contains(.primaryRecording) || others.contains(.secondaryRecording))
    }

    func testMonitorIsNotCleanWhenGlobalMonitorCannotBeCreated() {
        let monitor = HaasUserInputMonitor(
            excludedShortcutsProvider: { [] }, isAccessibilityTrusted: { true }, makeGlobalMonitor: { _ in nil })
        XCTAssertFalse(monitor.isClean(for: monitor.startWatching()))
    }

    func testMonitorIsNotCleanWhenAccessibilityIsLost() {
        var trusted = true
        let monitor = HaasUserInputMonitor(
            excludedShortcutsProvider: { [] }, isAccessibilityTrusted: { trusted }, makeGlobalMonitor: { _ in NSObject() })
        let token = monitor.startWatching()
        XCTAssertTrue(monitor.isClean(for: token))
        trusted = false
        XCTAssertFalse(monitor.isClean(for: token))
    }

    func testProviderIsReadOncePerWatch() {
        var reads = 0
        let monitor = HaasUserInputMonitor(
            excludedShortcutsProvider: { reads += 1; return [] }, isAccessibilityTrusted: { true },
            makeGlobalMonitor: { _ in NSObject() })
        _ = monitor.startWatching()
        XCTAssertEqual(reads, 1)
    }
}
