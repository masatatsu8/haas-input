import AppKit
import SwiftUI

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var notificationWindow: NSPanel?
    private var dismissTimer: Timer?
    private var notificationID: UUID?

    private init() {}

    func showNotification(
        title: String,
        type: AppNotificationView.NotificationType,
        duration: TimeInterval = 3.0,
        onTap: (() -> Void)? = nil,
        actionButton: (label: String, action: () -> Void)? = nil
    ) {
        dismissNotification()
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let id = UUID()
        notificationID = id
        if type == .error { SoundManager.shared.playEscSound() }

        let view = AppNotificationView(
            title: title,
            type: type,
            onClose: { [weak self] in self?.dismissNotification(ifCurrent: id) },
            onTap: onTap,
            actionButton: actionButton
        )
        let hostingController = NSHostingController(rootView: view)
        let panel = HaasNotificationPanel(
            contentRect: NSRect(origin: .zero, size: hostingController.view.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingController.view
        panel.isFloatingPanel = true
        panel.level = .mainMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.midX - panel.frame.width / 2,
            y: screen.visibleFrame.minY + 74
        ))
        notificationWindow = panel
        panel.orderFrontRegardless()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismissNotification(ifCurrent: id) }
        }
    }

    func dismissNotification() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        notificationID = nil
        notificationWindow?.close()
        notificationWindow = nil
    }

    private func dismissNotification(ifCurrent id: UUID) {
        guard notificationID == id else { return }
        dismissNotification()
    }
}

private final class HaasNotificationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
