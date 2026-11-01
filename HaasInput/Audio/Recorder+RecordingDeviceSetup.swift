import CoreAudio
import Foundation
import os

extension Recorder {
    func setupRecordingDeviceChangeObserver() {
        recordingDeviceChangeObserver = NotificationCenter.default.addObserver(
            forName: .recordingDeviceChangeRequired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let generation = self?.recordingGeneration,
                    let request = notification.object as? RecordingDeviceChangeRequest
                else { return }
                Task { [weak self] in
                    await self?.handleRecordingDeviceChange(request, expectedGeneration: generation)
                }
            }
        }
    }

    func startHardwareRecording(
        _ recorder: CoreAudioRecorder,
        to url: URL,
        deviceID: AudioDeviceID,
        expectedGeneration: UUID
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard recordingGeneration == expectedGeneration else {
                continuation.resume(throwing: CancellationError())
                return
            }
            let selectedChannels = deviceManager.selectedInputChannels(for: deviceID)
            audioSetupQueue.async {
                guard self.hasRecordingGeneration(expectedGeneration) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try recorder.startRecording(
                        toOutputFile: url, deviceID: deviceID, selectedInputChannels: selectedChannels,
                        isCurrent: { self.hasRecordingGeneration(expectedGeneration) }
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func showRecordingDeviceNotification(
        for deviceID: AudioDeviceID,
        isDeviceSwitch: Bool = false
    ) {
        guard let generation = recordingGeneration,
            let device = deviceManager.availableDevices.first(where: { $0.id == deviceID })
        else {
            return
        }

        // Core Audio object IDs can change on reconnect, or be reused for another input.
        // Compare the stable UID for every route, including closed-lid fallbacks.
        let lastDeviceUID = UserDefaults.standard.string(forKey: "lastUsedMicrophoneDeviceUID")
        guard device.uid != lastDeviceUID else { return }

        recordingDeviceNotificationTask?.cancel()
        // Let the caller finish recording startup before constructing the notification window.
        recordingDeviceNotificationTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled,
                self.recordingGeneration == generation,
                self.deviceManager.isRecordingActive,
                self.deviceManager.activeRecordingDeviceID == deviceID
            else { return }

            let title = isDeviceSwitch ? "マイクを切り替えました: %@" : "使用するマイク: %@"
            NotificationManager.shared.showNotification(
                title: String(format: title, device.name),
                type: .info
            )
            UserDefaults.standard.set(device.uid, forKey: "lastUsedMicrophoneDeviceUID")
            self.recordingDeviceNotificationTask = nil
        }
    }

    private func handleRecordingDeviceChange(
        _ request: RecordingDeviceChangeRequest, expectedGeneration: UUID
    ) async {
        guard recordingGeneration == expectedGeneration else { return }
        guard let fallbackDeviceID = request.fallbackDeviceID else {
            deviceManager.recordingDeviceChangeFinished()
            showNoFallbackNotification(reason: request.reason)
            return
        }
        guard let recorder else {
            deviceManager.recordingDeviceChangeFinished()
            return
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard recordingGeneration == expectedGeneration else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let selectedChannels = deviceManager.selectedInputChannels(for: fallbackDeviceID)
                audioSetupQueue.async {
                    guard self.hasRecordingGeneration(expectedGeneration) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        try recorder.switchDevice(
                            to: fallbackDeviceID, selectedInputChannels: selectedChannels,
                            isCurrent: { self.hasRecordingGeneration(expectedGeneration) }
                        )
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            guard recordingGeneration == expectedGeneration else { return }
            deviceManager.recordingDeviceChangeFinished(activeDeviceID: fallbackDeviceID)
            showRecordingDeviceNotification(for: fallbackDeviceID, isDeviceSwitch: true)
        } catch {
            guard recordingGeneration == expectedGeneration else { return }
            deviceManager.recordingDeviceChangeFinished()
            logger.error("Failed to switch recording devices: \(error, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: "別のマイクへ切り替えられませんでした。接続と設定を確認してください。",
                type: .error,
                duration: 7.0
            )
        }
    }

    private func showNoFallbackNotification(reason: RecordingDeviceChangeReason) {
        let presentation = AudioInputFailurePresentation.noUsableMicrophone(
            internalMicrophoneBlockedByClosedLid: reason == .closedLid
        )
        NotificationManager.shared.showNotification(
            title: presentation.title,
            type: .error,
            duration: 7.0,
            actionButton: (presentation.actionLabel, presentation.action)
        )
    }

}
