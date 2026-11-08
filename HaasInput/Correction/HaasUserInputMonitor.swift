import AppKit
import ApplicationServices
import Carbon
import Foundation
import os

/// アプリ自身が送る CGEvent に付ける印。見張りは、この印のあるイベントを利用者の操作として数えない。
enum HaasSyntheticInput {
    static let marker: Int64 = 0x4841_4153  // "HAAS"

    /// アプリ自身が送った操作か、アプリ自身の窓 (訂正の窓など) への操作。どちらも入力先の欄を変えない。
    /// アプリが前面にないと、自分の窓への操作も全体監視に届くことがある。
    /// ただし自分の窓からのドラッグは、選んだ文を入力先の欄へ落とせるので数える
    static func isOwnEvent(_ input: HaasObservedInput, sourceUserData: Int64, targetPID: Int64, ownPID: Int64) -> Bool {
        sourceUserData == marker || (targetPID == ownPID && input != .drag)
    }
}

/// 入力の後に利用者が行った操作。
enum HaasObservedInput: Equatable {
    case keyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags)
    case mouseDown(button: Int, modifiers: NSEvent.ModifierFlags)
    case scroll
    case drag
}

/// 入力した文字の後に、利用者が何か操作したかを数える純粋な状態。
/// 信頼できなくなったとき (監視を作れない、権限を失う) は invalidate で clean を失わせる。
struct HaasInputWatch: Equatable {
    private(set) var token: UUID?
    private(set) var isClean = false

    /// 新しい見張りを始め、その印を返す。古い印は二度と clean にならない。
    mutating func start() -> UUID {
        let newToken = UUID()
        token = newToken
        isClean = true
        return newToken
    }

    mutating func record(_ input: HaasObservedInput, isOwnEvent: Bool, shortcuts: [Shortcut]) {
        guard isClean, !isOwnEvent else { return }
        switch input {
        case .keyDown(let keyCode, let modifiers):
            if shortcuts.contains(where: { $0.matchesKeyEvent(keyCode: keyCode, modifierFlags: modifiers) }) { return }
        case .mouseDown(let button, let modifiers):
            if let number = UInt16(exactly: button),
                shortcuts.contains(where: { $0.matchesMouseEvent(buttonNumber: number, modifierFlags: modifiers) })
            {
                return
            }
        case .scroll, .drag:
            break
        }
        isClean = false
    }

    mutating func invalidate() {
        isClean = false
    }

    func isClean(for token: UUID) -> Bool {
        isClean && self.token == token
    }
}

@MainActor
protocol HaasInputWatching: AnyObject {
    func startWatching() -> UUID
    func isClean(for token: UUID) -> Bool
    func invalidate()
}

/// NSEvent の全体監視で、入力後の操作を見張る。ロジックは HaasInputWatch に置く。
/// 次のときは見張りを打ち切り、その印は二度と clean にしない。
/// - Secure Event Input が有効 (全体監視にキーが届かない)。見張りの間は一定の間隔で確かめる
/// - 除外するショートカットが変わった (古い一覧のままでは、解除したキーの入力を見逃す)
@MainActor
final class HaasUserInputMonitor: HaasInputWatching {
    static let shared = HaasUserInputMonitor()

    /// 見張りの間に Secure Event Input を確かめる間隔 (秒)
    static let secureInputPollInterval: TimeInterval = 0.25

    private static let observedMask: NSEvent.EventTypeMask = [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]

    private static let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "HaasCorrection")
    private var watch = HaasInputWatch()
    private var globalMonitor: Any?
    private var excludedShortcuts: [Shortcut] = []
    private let excludedShortcutsProvider: () -> [Shortcut]
    private let isAccessibilityTrusted: () -> Bool
    private let isSecureInputEnabled: () -> Bool
    private let startPolling: @MainActor (@escaping @MainActor () -> Void) -> (() -> Void)
    private let makeGlobalMonitor: (@escaping (NSEvent) -> Void) -> Any?
    /// 動いている確認を止める。見張りが clean の間だけ動かす
    private var stopPolling: (() -> Void)?
    private var shortcutObserver: NSObjectProtocol?

    /// - startPolling: 渡した処理を一定の間隔で呼び始め、止める処理を返す
    init(
        excludedShortcutsProvider: @escaping () -> [Shortcut] = HaasUserInputMonitor.defaultExcludedShortcuts,
        isAccessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        isSecureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        startPolling: @escaping @MainActor (@escaping @MainActor () -> Void) -> (() -> Void) =
            HaasUserInputMonitor.pollOnMainRunLoop,
        notificationCenter: NotificationCenter = .default,
        makeGlobalMonitor: @escaping (@escaping (NSEvent) -> Void) -> Any? = { handler in
            NSEvent.addGlobalMonitorForEvents(matching: HaasUserInputMonitor.observedMask, handler: handler)
        }
    ) {
        self.excludedShortcutsProvider = excludedShortcutsProvider
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.isSecureInputEnabled = isSecureInputEnabled
        self.startPolling = startPolling
        self.makeGlobalMonitor = makeGlobalMonitor
        // ショートカットが変わると除外の一覧が古くなるので、今の見張りを打ち切る
        shortcutObserver = notificationCenter.addObserver(
            forName: ShortcutStore.shortcutDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.invalidate() }
            } else {
                Task { @MainActor in self?.invalidate() }
            }
        }
    }

    /// 本番の確認。メインの run loop のタイマーで呼ぶ
    static func pollOnMainRunLoop(_ tick: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: secureInputPollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    /// 見張りの除外に使う一覧。録音のショートカットと訂正のショートカットだけで、
    /// 取消・直前の認識結果・履歴のキーは利用者の操作として数える。
    static func excludedShortcuts(primary: Shortcut?, secondary: Shortcut?, correction: Shortcut?) -> [Shortcut] {
        [primary, secondary, correction].compactMap { $0 }
    }

    /// 選択 (「指定する」か「使用しない」か) を踏まえた除外の一覧。「使用しない」の録音ショートカットは除外しない。
    static func excludedShortcuts(
        primarySelection: RecordingShortcutManager.ShortcutSelection, primary: Shortcut?,
        secondarySelection: RecordingShortcutManager.ShortcutSelection, secondary: Shortcut?,
        correction: Shortcut?
    ) -> [Shortcut] {
        excludedShortcuts(
            primary: primarySelection == .custom ? primary : nil,
            secondary: secondarySelection == .custom ? secondary : nil,
            correction: correction)
    }

    /// 既定の除外。保存内容を読むだけで、移行や書き込みはしない。
    static func defaultExcludedShortcuts() -> [Shortcut] {
        let defaults = UserDefaults.standard
        func selection(_ key: String, fallback: RecordingShortcutManager.ShortcutSelection)
            -> RecordingShortcutManager.ShortcutSelection
        {
            defaults.string(forKey: key).flatMap(RecordingShortcutManager.ShortcutSelection.init(rawValue:))
                ?? fallback
        }
        return excludedShortcuts(
            primarySelection: .custom, primary: ShortcutStore.shortcut(for: .primaryRecording),
            secondarySelection: selection("secondaryRecordingShortcut", fallback: .none),
            secondary: ShortcutStore.shortcut(for: .secondaryRecording),
            correction: ShortcutStore.shortcut(for: .correctLastInput))
    }

    func startWatching() -> UUID {
        let token = watch.start()
        // 除外の一覧は見張りを始めた時点の保存内容で固定する (イベントごとに読まない)
        excludedShortcuts = excludedShortcutsProvider()
        if globalMonitor == nil {
            globalMonitor = makeGlobalMonitor { [weak self] event in
                // 全体監視はメインスレッドで呼ばれる。記録を遅らせると、操作の後に clean と答えうるので同期で記録する
                MainActor.assumeIsolated {
                    // すでに clean でなければ、それ以上数えることはない
                    guard let self, self.watch.isClean, let observed = Self.observedInput(from: event) else { return }
                    let targetPID = event.cgEvent?.getIntegerValueField(.eventTargetUnixProcessID) ?? 0
                    let isOwn = HaasSyntheticInput.isOwnEvent(
                        observed, sourceUserData: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0,
                        targetPID: targetPID, ownPID: Int64(ProcessInfo.processInfo.processIdentifier))
                    self.watch.record(observed, isOwnEvent: isOwn, shortcuts: self.excludedShortcuts)
                    if !self.watch.isClean {
                        Self.logger.notice("watch result=userInput input=\(Self.kind(of: observed), privacy: .public) targetPID=\(targetPID, privacy: .public)")
                    }
                    self.updatePolling()
                }
            }
        }
        // 監視を作れない、権限がない、キーが届かない (Secure Event Input) ときは信頼できないので、clean にしない
        if globalMonitor == nil || !isAccessibilityTrusted() || isSecureInputEnabled() { watch.invalidate() }
        updatePolling()
        return token
    }

    func isClean(for token: UUID) -> Bool {
        if !isAccessibilityTrusted() || isSecureInputEnabled() { watch.invalidate() }
        updatePolling()
        return watch.isClean(for: token)
    }

    func invalidate() {
        watch.invalidate()
        updatePolling()
    }

    /// 見張りの間に Secure Event Input が一度でも有効になれば、見張りを打ち切る。無効に戻っても復活させない
    private func checkSecureInput() {
        if isSecureInputEnabled() { watch.invalidate() }
        updatePolling()
    }

    /// clean な見張りがある間だけ確認を動かす
    private func updatePolling() {
        if watch.isClean {
            guard stopPolling == nil else { return }
            stopPolling = startPolling { [weak self] in self?.checkSecureInput() }
        } else if let stop = stopPolling {
            stopPolling = nil
            stop()
        }
    }

    /// ログに出す操作の種類。キーコードや修飾キーは出さない
    private static func kind(of input: HaasObservedInput) -> String {
        switch input {
        case .keyDown: "keyDown"
        case .mouseDown: "mouseDown"
        case .scroll: "scroll"
        case .drag: "drag"
        }
    }

    private static func observedInput(from event: NSEvent) -> HaasObservedInput? {
        switch event.type {
        case .keyDown:
            return .keyDown(keyCode: event.keyCode, modifiers: event.modifierFlags)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .mouseDown(button: event.buttonNumber, modifiers: event.modifierFlags)
        case .scrollWheel:
            return .scroll
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return .drag
        default:
            return nil
        }
    }
}
