import CoreAudio
import SwiftUI

@MainActor
struct AudioSetupView: View {
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared
    @ObservedObject private var mediaController = MediaController.shared
    @ObservedObject private var playbackController = PlaybackController.shared
    @State private var microphoneSourceBeforePriorityOrder: MicrophoneSourceSelection = .systemDefault
    @State private var refreshIconRotation = 0.0
    @Environment(\.haasTextScale) private var textScale

    var body: some View {
        Form {
            Section {
                inputSettingsRows
            } header: {
                Text("音声入力")
            }

            if usesPriorityOrder {
                Section {
                    priorityOrderRows
                } header: {
                    Text("優先順位")
                }
            }

            Section {
                CustomSoundSettingsView()
            } header: {
                Text("録音の操作音")
            }

            Section {
                Toggle("録音中はMacの音量をミュート", isOn: $mediaController.isSystemMuteEnabled)

                Toggle("録音中はメディアの再生を一時停止", isOn: $playbackController.isPauseMediaEnabled)

                LabeledContent("再生を戻すまでの時間") {
                    resumeDelayMenu
                        .disabled(!canEditResumeDelay)
                }
                .foregroundStyle(canEditResumeDelay ? .primary : .secondary)
            } header: {
                Text("録音中の動作")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            if !usesPriorityOrder {
                microphoneSourceBeforePriorityOrder = currentMicrophoneSource
            }
        }
    }

    @ViewBuilder
    private var inputSettingsRows: some View {
        Picker("マイクの選び方", selection: inputRouteSelection) {
            Text("マイクを指定").tag(InputRoute.singleMicrophone)
            Text("優先順位").tag(InputRoute.priorityOrder)
        }
        .pickerStyle(.menu)

        if !usesPriorityOrder {
            Picker("マイク", selection: microphoneSourceSelection) {
                Text(systemDefaultSourceTitle).tag(MicrophoneSourceSelection.systemDefault)

                ForEach(audioDeviceManager.availableDevices, id: \.uid) { device in
                    Text(device.name).tag(MicrophoneSourceSelection.device(device.uid))
                }
            }
            .pickerStyle(.menu)

            if let deviceID = audioDeviceManager.resolveCurrentRecordingDevice().deviceID {
                AudioInputChannelsView(deviceID: deviceID)
            }
        }

        Button {
            refreshMicrophones()
        } label: {
            Label {
                Text("マイク一覧を更新")
            } icon: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(refreshIconRotation))
            }
        }
        .buttonStyle(.borderless)
        .help("マイク一覧を更新")
    }

    @ViewBuilder
    private var priorityOrderRows: some View {
        if prioritizedDevicesInDisplayOrder.isEmpty {
            Text("使用したい順にマイクを追加してください。接続されている上位のマイクを使います。")
                .foregroundStyle(.secondary)
        } else {
            ForEach(prioritizedDevicesInDisplayOrder) { device in
                priorityDeviceRow(for: device)
            }
        }

        if !availableDevicesNotInPriorityOrder.isEmpty {
            ForEach(availableDevicesNotInPriorityOrder, id: \.uid) { device in
                availablePriorityDeviceRow(for: device)
            }
        }
    }

    private var inputRouteSelection: Binding<InputRoute> {
        Binding(
            get: { usesPriorityOrder ? .priorityOrder : .singleMicrophone },
            set: { route in
                switch route {
                case .singleMicrophone:
                    selectSingleMicrophoneMode()
                case .priorityOrder:
                    selectPriorityOrderMode()
                }
            }
        )
    }

    private var microphoneSourceSelection: Binding<MicrophoneSourceSelection> {
        Binding(
            get: { currentMicrophoneSource },
            set: { selection in
                microphoneSourceBeforePriorityOrder = selection
                selectMicrophoneSource(selection)
            }
        )
    }

    private func availablePriorityDeviceRow(for device: (id: AudioDeviceID, uid: String, name: String)) -> some View {
        Button {
            audioDeviceManager.addPrioritizedDevice(uid: device.uid, name: device.name)
        } label: {
            HStack(spacing: 8) {
                Label(device.name, systemImage: "plus.circle")
                    .lineLimit(1)

                Spacer()

                Text("追加")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func priorityDeviceRow(for prioritizedDevice: PrioritizedDevice) -> some View {
        let device = audioDeviceManager.availableDevices.first { $0.uid == prioritizedDevice.id }
        let isAvailable = device != nil
        let isActive = device.map { audioDeviceManager.getCurrentDevice() == $0.id } ?? false

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(prioritizedDevice.priority + 1)")
                    .font(HaasFont.font(.body, scale: textScale).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22 * textScale, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(prioritizedDevice.name)
                        .foregroundStyle(isAvailable ? .primary : .secondary)
                        .lineLimit(1)

                    if !isAvailable {
                        Text("未接続")
                            .haasFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isActive {
                    Label("使用中", systemImage: "checkmark.circle.fill")
                        .haasFont(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }

                HStack(spacing: 4) {
                    Button {
                        movePrioritizedDeviceUp(prioritizedDevice)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(prioritizedDevice.id == prioritizedDevicesInDisplayOrder.first?.id)
                    .help("上へ移動")

                    Button {
                        movePrioritizedDeviceDown(prioritizedDevice)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(prioritizedDevice.id == prioritizedDevicesInDisplayOrder.last?.id)
                    .help("下へ移動")

                    Button {
                        audioDeviceManager.removePrioritizedDevice(id: prioritizedDevice.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .help("一覧から外す")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if let device {
                AudioInputChannelsView(deviceID: device.id)
            }
        }
    }

    private var currentMicrophoneSource: MicrophoneSourceSelection {
        switch audioDeviceManager.inputMode {
        case .systemDefault:
            return .systemDefault
        case .custom:
            if let selectedDeviceUID {
                return .device(selectedDeviceUID)
            }
            return .systemDefault
        case .prioritized:
            return microphoneSourceBeforePriorityOrder
        }
    }

    private func selectMicrophoneSource(_ selection: MicrophoneSourceSelection) {
        switch selection {
        case .systemDefault:
            audioDeviceManager.selectInputMode(.systemDefault)
        case .device(let uid):
            guard let device = audioDeviceManager.availableDevices.first(where: { $0.uid == uid }) else {
                audioDeviceManager.selectInputMode(.systemDefault)
                return
            }
            audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: device.id)
        }
    }

    private func selectSingleMicrophoneMode() {
        selectMicrophoneSource(microphoneSourceBeforePriorityOrder)
    }

    private func selectPriorityOrderMode() {
        if !usesPriorityOrder {
            microphoneSourceBeforePriorityOrder = currentMicrophoneSource
        }
        audioDeviceManager.selectInputMode(.prioritized)
    }

    private var selectedDeviceUID: String? {
        guard let selectedDeviceID = audioDeviceManager.selectedDeviceID else { return nil }
        return audioDeviceManager.availableDevices.first { $0.id == selectedDeviceID }?.uid
    }

    private var systemDefaultSourceTitle: String {
        guard let name = audioDeviceManager.getSystemDefaultDeviceName() else {
            return String(localized: "システムの既定")
        }
        return String(format: String(localized: "システムの既定 (%@)"), name)
    }

    private func refreshMicrophones() {
        withAnimation(.easeInOut(duration: 0.35)) {
            refreshIconRotation += 360
        }
        audioDeviceManager.loadAvailableDevices()
    }

    private var usesPriorityOrder: Bool {
        audioDeviceManager.inputMode == .prioritized
    }

    private var prioritizedDevicesInDisplayOrder: [PrioritizedDevice] {
        audioDeviceManager.prioritizedDevices.sorted { $0.priority < $1.priority }
    }

    private var availableDevicesNotInPriorityOrder: [(id: AudioDeviceID, uid: String, name: String)] {
        audioDeviceManager.availableDevices.filter { device in
            !audioDeviceManager.prioritizedDevices.contains { $0.id == device.uid }
        }
    }

    private var resumeDelayMenu: some View {
        Picker("再生を戻すまでの時間", selection: $mediaController.audioResumptionDelay) {
            Text("すぐに戻す").tag(0.0)
            Text("1秒").tag(1.0)
            Text("2秒").tag(2.0)
            Text("3秒").tag(3.0)
            Text("4秒").tag(4.0)
            Text("5秒").tag(5.0)
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private var canEditResumeDelay: Bool {
        mediaController.isSystemMuteEnabled || playbackController.isPauseMediaEnabled
    }

    private func movePrioritizedDeviceUp(_ device: PrioritizedDevice) {
        var devices = prioritizedDevicesInDisplayOrder
        guard let currentIndex = devices.firstIndex(where: { $0.id == device.id }),
            currentIndex > 0
        else { return }

        devices.swapAt(currentIndex, currentIndex - 1)
        updatePriorities(devices)
    }

    private func movePrioritizedDeviceDown(_ device: PrioritizedDevice) {
        var devices = prioritizedDevicesInDisplayOrder
        guard let currentIndex = devices.firstIndex(where: { $0.id == device.id }),
            currentIndex < devices.count - 1
        else { return }

        devices.swapAt(currentIndex, currentIndex + 1)
        updatePriorities(devices)
    }

    private func updatePriorities(_ devices: [PrioritizedDevice]) {
        let updatedDevices = devices.enumerated().map { index, device in
            PrioritizedDevice(id: device.id, name: device.name, priority: index, modelUID: device.modelUID)
        }
        audioDeviceManager.updatePriorities(devices: updatedDevices)
    }
}

private enum MicrophoneSourceSelection: Hashable {
    case systemDefault
    case device(String)
}

private enum InputRoute: Hashable {
    case singleMicrophone
    case priorityOrder
}
