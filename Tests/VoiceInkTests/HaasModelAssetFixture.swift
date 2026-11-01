import Foundation
@testable import VoiceInk

final class HaasModelAssetFixture: @unchecked Sendable {
    let root: URL
    let bundle: URL
    let cache: URL
    let manifest: HaasModelManifest
    let session: URLSession
    let downloader: HaasModelDownloader
    let modelBody: Data
    private let state = HaasModelHTTPFixture.State()
    lazy var assets = makeAssets()

    init(largeModel: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HaasDownloadTests-" + UUID().uuidString)
        bundle = root.appendingPathComponent("Bundle")
        cache = root.appendingPathComponent("Cache")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let helper = bundle.appendingPathComponent("speech")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try Data("library fixture".utf8).write(to: bundle.appendingPathComponent("libspeech.3.dylib"))
        modelBody = largeModel ? Data(count: 262_144) : Data("abc".utf8)
        let smallHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let modelHash = largeModel ? "8a39d2abd3999ab73c34db2476849cddf303ce389b35826850f9a700589b4a90" : smallHash
        let revision = String(repeating: "a", count: 40)
        var sources: [String: Any] = [:]
        var files: [String: Any] = [:]
        for kind in HaasModelAsset.Kind.allCases {
            let checksum = kind == .recognition ? modelHash : smallHash
            let size = kind == .recognition ? modelBody.count : 3
            let url = URL(string: "https://huggingface.co/voiceink-tests/\(root.lastPathComponent)/resolve/\(revision)/\(kind.filename)")!
            sources[kind.filename] = ["url": url.absoluteString, "sha256": checksum]
            files[kind.filename] = ["sha256": checksum, "size": size]
            HaasModelHTTPFixture.register(url, state: state)
        }
        let document: [String: Any] = ["model_revision": revision, "vad_revision": revision,
            "model_layout": 4, "model_quantization": "Q8_0", "sources": sources, "files": files]
        let manifestURL = bundle.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: document).write(to: manifestURL)
        manifest = try HaasModelManifest(contentsOf: manifestURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HaasModelHTTPFixture.self]
        session = URLSession(configuration: configuration)
        downloader = HaasModelDownloader(session: session)
        respond(.recognition, body: modelBody)
        respond(.vad, body: Data("abc".utf8))
    }

    var requestCount: Int { state.lock.withLock { state.requests } }
    var partials: [URL] {
        (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "partial" }
    }
    func makeAssets() -> HaasModelAssets {
        HaasModelAssets(bundledDirectory: bundle, cacheDirectory: cache, downloader: downloader)
    }
    func cacheURL(_ kind: HaasModelAsset.Kind) -> URL { assets.cacheURL(for: manifest.assets.first { $0.kind == kind }!) }
    func respond(
        _ kind: HaasModelAsset.Kind, status: Int = 200, body: Data = Data(), chunkDelay: Double = 0,
        redirect: URL? = nil
    ) {
        let url = manifest.assets.first { $0.kind == kind }!.sourceURL
        state.lock.withLock {
            state.responses[url] = HaasModelHTTPFixture.Response(
                status: status, body: body, chunkDelay: chunkDelay, redirect: redirect)
        }
    }
    func cleanUp() {
        session.invalidateAndCancel()
        for asset in manifest.assets { HaasModelHTTPFixture.unregister(asset.sourceURL) }
        try? FileManager.default.removeItem(at: root)
    }
}

private final class HaasModelHTTPFixture: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let body: Data
        let chunkDelay: Double
        let redirect: URL?
    }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests = 0
        var responses: [URL: Response] = [:]
    }
    private static let registryLock = NSLock()
    private static var states: [URL: State] = [:]
    private let lock = NSLock()
    private var stopped = false
    static func register(_ url: URL, state: State) { registryLock.withLock { states[url] = state } }
    static func unregister(_ url: URL) { _ = registryLock.withLock { states.removeValue(forKey: url) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { lock.withLock { stopped = true } }
    override func startLoading() {
        guard let url = request.url, let state = Self.registryLock.withLock({ Self.states[url] }),
            let response = state.lock.withLock({ () -> Response? in
                state.requests += 1
                return state.responses[url]
            })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let redirect = response.redirect {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect),
                redirectResponse: HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": redirect.absoluteString])!)
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil,
            headerFields: ["Content-Length": String(response.body.count)])!, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { [self] in
            for offset in stride(from: 0, to: response.body.count, by: 4_096) {
                if lock.withLock({ stopped }) { return }
                if response.chunkDelay > 0 { Thread.sleep(forTimeInterval: response.chunkDelay) }
                if lock.withLock({ stopped }) { return }
                client?.urlProtocol(self, didLoad: response.body.subdata(in: offset..<min(offset + 4_096, response.body.count)))
            }
            if !lock.withLock({ stopped }) { client?.urlProtocolDidFinishLoading(self) }
        }
    }
}
