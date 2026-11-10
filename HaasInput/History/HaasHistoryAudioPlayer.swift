import AVFoundation
import Combine
import SwiftUI
import os

struct HaasHistoryAudioPlayer: View {
    let url: URL
    @StateObject private var playback = HaasAudioPlayback()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: playback.toggle) {
                    Label(playback.isPlaying ? "一時停止" : "再生", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(playback.errorMessage != nil)
                Text(time(playback.position)).monospacedDigit()
                Slider(value: Binding(get: { playback.position }, set: playback.seek), in: 0...max(playback.duration, 0.01))
                    .accessibilityLabel("再生位置")
                    .disabled(playback.duration == 0)
                Text(time(playback.duration)).monospacedDigit()
                Button("\(playback.rate.formatted())倍") { playback.cycleRate() }
                    .help("再生速度を切り替えます")
            }
            if let message = playback.errorMessage { Text(message).haasFont(.caption).foregroundStyle(.red) }
        }
        .onAppear { playback.load(url) }
        .onChange(of: url) { _, value in playback.load(value) }
        .onDisappear { playback.stop() }
    }

    private func time(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

@MainActor
private final class HaasAudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var rate: Double = 1
    @Published private(set) var errorMessage: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "HistoryAudio")

    func load(_ url: URL) {
        stop()
        player = nil
        position = 0
        duration = 0
        errorMessage = nil
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.enableRate = true
            player.rate = Float(rate)
            self.player = player
            duration = player.duration
        } catch {
            logger.error("Audio load failed: \(String(describing: error), privacy: .private)")
            errorMessage = "録音を再生できません。ファイルが移動・削除されていないか確認してください。"
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying { stop(); return }
        if player.currentTime >= player.duration { player.currentTime = 0 }
        guard player.play() else { errorMessage = "録音の再生を開始できませんでした。"; return }
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.position = self?.player?.currentTime ?? 0 }
        }
    }

    func stop() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func seek(_ seconds: Double) {
        player?.currentTime = seconds
        position = seconds
    }

    func cycleRate() {
        rate = rate == 1 ? 1.5 : rate == 1.5 ? 2 : 1
        player?.rate = Float(rate)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stop()
            self?.position = self?.duration ?? 0
            if !flag { self?.errorMessage = "録音の再生中に問題が発生しました。" }
        }
    }

    deinit { timer?.invalidate() }
}
