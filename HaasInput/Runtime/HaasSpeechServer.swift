import AppKit
import Darwin
import Foundation
import os

@MainActor
final class HaasSpeechServer {
    var onUnexpectedExit: ((Error) -> Void)?

    private let configuration: HaasRuntimeConfiguration
    private var process: Process?
    private var outputPipe: Pipe?
    private var pendingOutput = Data()
    private var diagnostics = ""
    private var startup: CheckedContinuation<URL, Error>?
    private var startupDeadline: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.tatsumi.VoiceInkHaas", category: "HaasSpeechServer")

    init(configuration: HaasRuntimeConfiguration) {
        self.configuration = configuration
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if let process { Self.terminateOwnedProcess(process) }
    }

    func start() async throws -> URL {
        try configuration.validate()
        guard process == nil else { throw HaasRuntimeError.startup("既に起動しています。") }

        let child = Process()
        let pipe = Pipe()
        child.executableURL = configuration.executableURL
        child.arguments = [
            "serve", configuration.modelURL.path, configuration.vadModelURL.path,
            "--host", "127.0.0.1", "--port", "0", "--threads", "4", "--device", "MTL0",
        ]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe
        child.standardError = pipe
        process = child
        outputPipe = pipe
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.receivedOutput(data) }
        }
        child.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in self?.exited(status: status) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                guard process === child, !Task.isCancelled else {
                    failStartup(CancellationError())
                    return
                }
                do {
                    try child.run()
                    startupDeadline = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(120)) } catch { return }
                        self?.failStartup(HaasRuntimeError.timeout("起動"))
                    }
                } catch {
                    failStartup(HaasRuntimeError.startup(error.localizedDescription))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        onUnexpectedExit = nil
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        startupDeadline?.cancel()
        startupDeadline = nil
        startup?.resume(throwing: CancellationError())
        startup = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        guard let child = process else { return }
        process = nil
        child.terminationHandler = nil
        Self.terminateOwnedProcess(child)
    }

    private nonisolated static func terminateOwnedProcess(_ child: Process) {
        guard child.isRunning else { return }
        child.terminate()
        let graceDeadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        while child.isRunning && ContinuousClock.now < graceDeadline {
            usleep(10_000)
        }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            let killDeadline = ContinuousClock.now.advanced(by: .milliseconds(100))
            while child.isRunning && ContinuousClock.now < killDeadline {
                usleep(10_000)
            }
        }
    }

    private func receivedOutput(_ data: Data) {
        guard process != nil else { return }
        pendingOutput.append(data)
        while let newline = pendingOutput.firstIndex(of: 10) {
            let line = String(decoding: pendingOutput[..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pendingOutput.removeSubrange(...newline)
            diagnostics = String((diagnostics + line + "\n").suffix(8_192))
            if line.hasPrefix("Ready at "),
                let url = URL(string: String(line.dropFirst("Ready at ".count))),
                url.scheme == "http", url.host == "127.0.0.1", let port = url.port, (1...65_535).contains(port)
            {
                startupDeadline?.cancel()
                startupDeadline = nil
                startup?.resume(returning: url)
                startup = nil
            }
        }
        if pendingOutput.count > 65_536 {
            failStartup(HaasRuntimeError.startup("起動応答が長すぎます。"))
        }
    }

    private func exited(status: Int32) {
        guard process != nil else { return }
        let error = HaasRuntimeError.startup(
            diagnostics.isEmpty ? "終了コード \(status)" : String(diagnostics.suffix(1_024)))
        if startup != nil {
            failStartup(error)
        } else {
            let handler = onUnexpectedExit
            stop()
            handler?(error)
        }
    }

    private func failStartup(_ error: Error) {
        logger.error("Haas startup failed: \(String(reflecting: error), privacy: .private)")
        startup?.resume(throwing: error)
        startup = nil
        stop()
    }
}
