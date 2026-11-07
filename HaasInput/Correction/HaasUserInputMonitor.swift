import AppKit
import ApplicationServices
import Foundation

/// アプリ自身が送る CGEvent に付ける印。見張りは、この印のあるイベントを利用者の操作として数えない。
enum HaasSyntheticInput {
    static let marker: Int64 = 0x4841_4153  // "HAAS"
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
@MainActor
final class HaasUserInputMonitor: HaasInputWatching {
    static let shared = HaasUserInputMonitor()

    private static let observedMask: NSEvent.EventTypeMask = [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]

    private var watch = HaasInputWatch()
    private var globalMonitor: Any?
    private let excludedShortcutsProvider: () -> [Shortcut]
    private let isAccessibilityTrusted: () -> Bool
    private let makeGlobalMonitor: (@escaping (NSEvent) -> Void) -> Any?

    init(
        excludedShortcutsProvider: @escaping () -> [Shortcut] = HaasUserInputMonitor.defaultExcludedShortcuts,
        isAccessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        makeGlobalMonitor: @escaping (@escaping (NSEvent) -> Void) -> Any? = { handler in
            NSEvent.addGlobalMonitorForEvents(matching: HaasUserInputMonitor.observedMask, handler: handler)
        }
    ) {
        self.excludedShortcutsProvider = excludedShortcutsProvider
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.makeGlobalMonitor = makeGlobalMonitor
    }

    /// 見張りの除外に使う一覧。録音のショートカットと訂正のショートカットだけで、
    /// 取消・直前の認識結果・履歴のキーは利用者の操作として数える。
    static func excludedShortcuts(primary: Shortcut?, secondary: Shortcut?, correction: Shortcut?) -> [Shortcut] {
        [primary, secondary, correction].compactMap { $0 }
    }

    /// 既定の除外。有効な録音のショートカット (1つ目と、「使用しない」でない2つ目) を保存内容から取る。
    /// 訂正のショートカットは、その操作が加わる段階で足す。
    static func defaultExcludedShortcuts() -> [Shortcut] {
        let primary = ShortcutMigration.migrateShortcutSelection(action: .primaryRecording, allowsNone: false)
        let secondary = ShortcutMigration.migrateShortcutSelection(action: .secondaryRecording, allowsNone: true)
        return excludedShortcuts(
            primary: primary == .custom ? ShortcutStore.shortcut(for: .primaryRecording) : nil,
            secondary: secondary == .custom ? ShortcutStore.shortcut(for: .secondaryRecording) : nil,
            correction: nil)
    }

    func startWatching() -> UUID {
        let token = watch.start()
        if globalMonitor == nil {
            globalMonitor = makeGlobalMonitor { [weak self] event in
                guard let observed = Self.observedInput(from: event) else { return }
                let isOwn = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == HaasSyntheticInput.marker
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.watch.record(
                        observed, isOwnEvent: isOwn, shortcuts: self.excludedShortcutsProvider())
                }
            }
        }
        // 監視を作れない、または権限がないときは信頼できないので、clean にしない
        if globalMonitor == nil || !isAccessibilityTrusted() { watch.invalidate() }
        return token
    }

    func isClean(for token: UUID) -> Bool {
        if !isAccessibilityTrusted() { watch.invalidate() }
        return watch.isClean(for: token)
    }

    func invalidate() {
        watch.invalidate()
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
