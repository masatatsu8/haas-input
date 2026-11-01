import Foundation

struct AudioInputFailurePresentation {
    let title: String
    let actionLabel: String
    let action: () -> Void

    @MainActor
    static func noUsableMicrophone(
        internalMicrophoneBlockedByClosedLid: Bool
    ) -> AudioInputFailurePresentation {
        presentation(for: .noUsableMicrophone(
            internalMicrophoneBlockedByClosedLid: internalMicrophoneBlockedByClosedLid
        ))
    }

    @MainActor
    static func audioSystemNotRunning() -> AudioInputFailurePresentation {
        presentation(for: .audioSystemNotRunning)
    }

    private static func presentation(for error: Recorder.RecorderError) -> AudioInputFailurePresentation {
        AudioInputFailurePresentation(
            title: error.errorDescription ?? "録音を開始できませんでした。",
            actionLabel: "録音設定を開く",
            action: { NotificationCenter.default.post(name: .showAudioSettingsRequested, object: nil) }
        )
    }
}
