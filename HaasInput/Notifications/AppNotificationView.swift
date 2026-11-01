import SwiftUI

struct AppNotificationView: View {
    let title: String
    let type: NotificationType
    let onClose: () -> Void
    let onTap: (() -> Void)?
    var actionButton: (label: String, action: () -> Void)? = nil

    enum NotificationType {
        case error
        case warning
        case info
        case success

        var iconName: String {
            switch self {
            case .error: return "xmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            }
        }

        var iconColor: Color {
            switch self {
            case .error: return .red
            case .warning: return .orange
            case .info: return .blue
            case .success: return .green
            }
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: type.iconName)
                .font(.system(size: 18))
                .foregroundStyle(type.iconColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionButton {
                Button(actionButton.label) {
                    actionButton.action()
                    onClose()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("通知を閉じる")
        }
        .padding(14)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.secondary.opacity(0.2), lineWidth: 0.5)
        }
        .onTapGesture {
            if let onTap {
                onTap()
                onClose()
            }
        }
    }
}
