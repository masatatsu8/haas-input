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

    /// 間隔ごとの確認を手で進める偽物
    private final class FakePolling {
        private(set) var tick: (@MainActor () -> Void)?
        private(set) var starts = 0
        private(set) var stops = 0
        var isRunning: Bool { tick != nil }

        func start(_ tick: @escaping @MainActor () -> Void) -> () -> Void {
            starts += 1
            self.tick = tick
            return { [weak self] in
                self?.stops += 1
                self?.tick = nil
            }
        }
    }

    private func makeMonitor(
        trusted: @escaping () -> Bool = { true }, secure: @escaping () -> Bool = { false },
        polling: FakePolling = FakePolling(), center: NotificationCenter = NotificationCenter(),
        provider: @escaping () -> [Shortcut] = { [] },
        makeGlobalMonitor: @escaping (@escaping (NSEvent) -> Void) -> Any? = { _ in NSObject() }
    ) -> HaasUserInputMonitor {
        HaasUserInputMonitor(
            excludedShortcutsProvider: provider, isAccessibilityTrusted: trusted, isSecureInputEnabled: secure,
            startPolling: { polling.start($0) }, notificationCenter: center, makeGlobalMonitor: makeGlobalMonitor)
    }

    func testMonitorIsNotCleanWhenGlobalMonitorCannotBeCreated() {
        let monitor = makeMonitor(makeGlobalMonitor: { _ in nil })
        XCTAssertFalse(monitor.isClean(for: monitor.startWatching()))
    }

    func testMonitorIsNotCleanWhenAccessibilityIsLost() {
        var trusted = true
        let monitor = makeMonitor(trusted: { trusted })
        let token = monitor.startWatching()
        XCTAssertTrue(monitor.isClean(for: token))
        trusted = false
        XCTAssertFalse(monitor.isClean(for: token))
    }

    func testProviderIsReadOncePerWatch() {
        var reads = 0
        let monitor = makeMonitor(provider: { reads += 1; return [] })
        _ = monitor.startWatching()
        XCTAssertEqual(reads, 1)
    }

    func testSecureInputDuringWatchInvalidatesIrreversibly() {
        var secure = false
        let polling = FakePolling()
        let monitor = makeMonitor(secure: { secure }, polling: polling)
        let token = monitor.startWatching()
        XCTAssertTrue(polling.isRunning, "見張りの間は確認を動かす")
        polling.tick?()
        XCTAssertTrue(monitor.isClean(for: token))

        // 見張りの途中で一時的に Secure Event Input が有効になり、また無効に戻る
        secure = true
        polling.tick?()
        secure = false
        XCTAssertFalse(monitor.isClean(for: token), "無効に戻っても、確定時の確認だけで資格を戻さない")
        XCTAssertFalse(polling.isRunning, "打ち切った見張りでは確認を止める")
    }

    func testSecureInputSeenAtCheckOrStartIsNotClean() {
        var secure = false
        let monitor = makeMonitor(secure: { secure })
        let token = monitor.startWatching()
        secure = true
        XCTAssertFalse(monitor.isClean(for: token))
        secure = false
        XCTAssertFalse(monitor.isClean(for: token))

        secure = true
        let started = monitor.startWatching()
        secure = false
        XCTAssertFalse(monitor.isClean(for: started))
    }

    func testPollingRunsOnlyWhileWatchIsClean() {
        let polling = FakePolling()
        let monitor = makeMonitor(polling: polling)
        XCTAssertFalse(polling.isRunning)
        _ = monitor.startWatching()
        _ = monitor.startWatching()
        XCTAssertEqual(polling.starts, 1, "続けて始めても確認は1つだけ")
        monitor.invalidate()
        XCTAssertFalse(polling.isRunning)
        XCTAssertEqual(polling.stops, 1)
        _ = monitor.startWatching()
        XCTAssertEqual(polling.starts, 2)
    }

    func testShortcutChangeInvalidatesWatch() {
        let center = NotificationCenter()
        let released = Shortcut.key(keyCode: 0, modifierFlags: [.option])
        var excluded = [released]
        let monitor = makeMonitor(center: center, provider: { excluded })
        let token = monitor.startWatching()
        XCTAssertTrue(monitor.isClean(for: token))

        // 予備のショートカットを解除した。古い除外の一覧のままでは、そのキーの入力を見逃す
        excluded = []
        center.post(name: ShortcutStore.shortcutDidChange, object: ShortcutAction.secondaryRecording)
        XCTAssertFalse(monitor.isClean(for: token))
        // 新しく始めた見張りは、今の一覧で数える
        let fresh = monitor.startWatching()
        XCTAssertTrue(monitor.isClean(for: fresh))
        XCTAssertFalse(monitor.isClean(for: token))
    }
}
