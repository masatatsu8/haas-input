import SwiftUI
import UniformTypeIdentifiers

struct CustomSoundSettingsView: View {
    @StateObject private var customSoundManager = CustomSoundManager.shared
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    private enum SoundMenuSelection: Hashable {
        case none
        case builtIn(CustomSoundManager.BuiltInSound)
        case custom
    }

    var body: some View {
        Group {
            LabeledContent("録音開始の音") {
                soundControls(for: .start)
            }

            LabeledContent("録音終了の音") {
                soundControls(for: .stop)
            }
        }
        .alert(alertTitle, isPresented: $showingAlert) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    @ViewBuilder
    private func soundControls(for type: CustomSoundManager.SoundType) -> some View {
        let selection = customSoundManager.soundSelection(for: type)
        let isCustom = selection.isCustom
        let fileName = customSoundManager.getSoundDisplayName(for: type)
        let isEnabled = selection.isEnabled

        HStack(spacing: 8) {
            Picker("操作音", selection: soundSelectionBinding(for: type)) {
                Text("なし").tag(SoundMenuSelection.none)

                ForEach(CustomSoundManager.BuiltInSound.allCases) { sound in
                    Text(sound.displayName).tag(SoundMenuSelection.builtIn(sound))
                }

                if isCustom || fileName != nil {
                    Text(String(format: String(localized: "選択した音: %@"), fileName ?? String(localized: "選択した音"))).tag(
                        SoundMenuSelection.custom)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 116, alignment: .trailing)
            .fixedSize()
            .help("操作音を選ぶ")

            Button {
                if type == .start {
                    SoundManager.shared.playStartSound()
                } else {
                    SoundManager.shared.playStopSound()
                }
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!isEnabled)
            .help("音を確認")

            Button {
                selectSound(for: type)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("音声ファイルを選ぶ")

            if !customSoundManager.isDefaultSelection(for: type) {
                Button {
                    if !isEnabled || isCustom {
                        customSoundManager.resetSoundToDefault(for: type)
                    } else {
                        customSoundManager.selectBuiltInSound(type.defaultBuiltInSound, for: type)
                    }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("初期設定に戻す")
            }
        }
    }

    private func soundSelectionBinding(for type: CustomSoundManager.SoundType) -> Binding<SoundMenuSelection> {
        Binding(
            get: {
                switch customSoundManager.soundSelection(for: type) {
                case .none:
                    return .none
                case .builtIn(let sound):
                    return .builtIn(sound)
                case .custom:
                    return .custom
                }
            },
            set: { selection in
                switch selection {
                case .none:
                    customSoundManager.selectNoSound(for: type)
                case .builtIn(let sound):
                    customSoundManager.selectBuiltInSound(sound, for: type)
                case .custom:
                    customSoundManager.useCustomSound(for: type)
                }
            }
        )
    }

    private func selectSound(for type: CustomSoundManager.SoundType) {
        let panel = NSOpenPanel()
        panel.title = type == .start ? "録音開始の音を選ぶ" : "録音終了の音を選ぶ"
        panel.message = String(localized: "操作音として使う音声ファイルを選んでください。")
        panel.allowedContentTypes = [
            UTType.audio,
            UTType.mp3,
            UTType.wav,
            UTType.aiff,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            Task { @MainActor in
                let result = await customSoundManager.setCustomSound(url: url, for: type)
                if case .failure = result {
                    alertTitle = "この音声ファイルは使えません"
                    alertMessage = "ファイルの形式・長さ・読み取り権限を確認し、選び直してください。"
                    showingAlert = true
                }
            }
        }
    }
}

