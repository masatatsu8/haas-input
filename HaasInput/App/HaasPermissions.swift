import AppKit
import ApplicationServices
import AVFoundation
import Combine

@MainActor
final class HaasPermissions: ObservableObject {
    @Published private(set) var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    var microphoneGranted: Bool { microphoneStatus == .authorized }

    func refresh() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestMicrophone() {
        if microphoneStatus == .notDetermined {
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                refresh()
            }
        } else {
            openPrivacyPane("Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacyPane("Privacy_Accessibility")
        refresh()
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
