import CoreAudio
import SwiftUI

@MainActor
struct AudioInputChannelsView: View {
    let deviceID: AudioDeviceID
    @ObservedObject private var deviceManager = AudioDeviceManager.shared

    private var channels: [AudioInputChannel] {
        deviceManager.inputChannelsByDevice[deviceID] ?? []
    }

    private var savedChannels: [UInt32]? {
        deviceManager.selectedInputChannels(for: deviceID)
    }

    private var selectedChannel: UInt32? {
        AudioInputChannelSelection.validatedChannels(savedChannels, deviceChannelCount: UInt32(channels.count))?.first
    }

    private var channelSelection: Binding<UInt32?> {
        Binding(
            get: { selectedChannel },
            set: { deviceManager.setInputChannels($0.map { [$0] }, for: deviceID) }
        )
    }

    var body: some View {
        // Built-in microphone arrays keep their driver-managed automatic configuration.
        if channels.count > 1, !deviceManager.isInternalMicrophone(deviceID) {
            VStack(alignment: .leading, spacing: 4) {
                Picker("入力チャンネル", selection: channelSelection) {
                    Text("自動").tag(nil as UInt32?)

                    ForEach(channels) { channel in
                        Text(channelTitle(channel)).tag(Optional(channel.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(deviceManager.isRecordingActive)

                if savedChannels != nil, selectedChannel == nil {
                    Text("保存した入力チャンネルを利用できません。利用できるようになるまでは自動で選びます。")
                        .haasFont(.caption)
                        .foregroundStyle(.secondary)
                } else if deviceManager.isRecordingActive {
                    Text("入力チャンネルは録音を止めてから変更してください。")
                        .haasFont(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("マイクを接続した入力を選びます。「自動」では機器の推奨入力を使います。")
                        .haasFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func channelTitle(_ channel: AudioInputChannel) -> String {
        if let name = channel.name {
            return String(format: String(localized: "入力 %u (%@)"), channel.id, name)
        }
        return String(format: String(localized: "入力 %u"), channel.id)
    }
}
