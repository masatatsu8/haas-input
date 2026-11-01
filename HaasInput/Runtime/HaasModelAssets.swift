import Foundation

final class HaasModelAssets: Sendable {
    static let shared: HaasModelAssets = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 3_600
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppStorageIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("HaasModels", isDirectory: true)
        return HaasModelAssets(
            bundledDirectory: HaasRuntimeConfiguration.bundledDirectory(), cacheDirectory: cache,
            downloader: HaasModelDownloader(session: URLSession(configuration: configuration)))
    }()

    let bundledDirectory: URL
    let cacheDirectory: URL
    private let downloader: HaasModelDownloader
    private var cache: HaasModelCache { HaasModelCache(rootURL: cacheDirectory) }

    init(bundledDirectory: URL, cacheDirectory: URL, downloader: HaasModelDownloader) {
        self.bundledDirectory = bundledDirectory
        self.cacheDirectory = cacheDirectory
        self.downloader = downloader
    }

    func resolvedConfiguration(for selection: HaasRuntimeSelection) throws -> HaasRuntimeConfiguration {
        let base = try selectedConfiguration(selection)
        let defaults = defaultKinds(selection)
        if defaults.isEmpty { return base }
        let manifest = try HaasModelManifest(contentsOf: bundledDirectory.appendingPathComponent("manifest.json"))
        var locations: [HaasModelAsset.Kind: URL] = [:]
        for asset in manifest.assets where defaults.contains(asset.kind) {
            let bundled = bundledDirectory.appendingPathComponent(asset.filename)
            let cached = cacheURL(for: asset)
            try cache.validateStorage(for: asset, receiptSources: [bundled, cached])
            if try cache.isVerified(bundled, asset: asset) { locations[asset.kind] = bundled }
            else if try cache.isVerified(cached, asset: asset) { locations[asset.kind] = cached }
            else { throw HaasModelDownloadError.missingModel(asset.displayName) }
        }
        return replacingDefaults(in: base, locations: locations)
    }

    func prepare(
        _ selection: HaasRuntimeSelection, downloadMissing: Bool = true,
        progress: @escaping @Sendable (HaasModelPreparationProgress) -> Void = { _ in }
    ) async throws -> HaasRuntimeConfiguration {
        let task = Task.detached(priority: .utility) { [self] in
            try await prepareFiles(selection, downloadMissing: downloadMissing, progress: progress)
        }
        return try await withTaskCancellationHandler {
            let configuration = try await task.value
            try Task.checkCancellation()
            return configuration
        } onCancel: { task.cancel() }
    }

    func cacheURL(for asset: HaasModelAsset) -> URL {
        cache.modelURL(for: asset)
    }

    private func prepareFiles(
        _ selection: HaasRuntimeSelection, downloadMissing: Bool,
        progress: @escaping @Sendable (HaasModelPreparationProgress) -> Void
    ) async throws -> HaasRuntimeConfiguration {
        try Task.checkCancellation()
        progress(HaasModelPreparationProgress(phase: .checking))
        let base = try selectedConfiguration(selection)
        let defaults = defaultKinds(selection)
        if defaults.isEmpty { return base }
        let manifest = try HaasModelManifest(contentsOf: bundledDirectory.appendingPathComponent("manifest.json"))
        for asset in manifest.assets where defaults.contains(asset.kind) {
            try cache.validateStorage(for: asset, receiptSources: [
                bundledDirectory.appendingPathComponent(asset.filename), cacheURL(for: asset),
            ])
        }
        var missing: [HaasModelAsset] = []
        for asset in manifest.assets where defaults.contains(asset.kind) {
            progress(HaasModelPreparationProgress(phase: .checking, assetName: asset.displayName))
            let bundled = bundledDirectory.appendingPathComponent(asset.filename)
            if try verifyIfAvailable(bundled, asset: asset) { continue }
            if try verifyIfAvailable(cacheURL(for: asset), asset: asset) { continue }
            missing.append(asset)
        }
        if !downloadMissing, let asset = missing.first { throw HaasModelDownloadError.missingModel(asset.displayName) }
        let total = missing.reduce(Int64(0)) { $0 + $1.byteCount }
        var completed: Int64 = 0
        for asset in missing {
            try Task.checkCancellation()
            let previousBytes = completed
            progress(HaasModelPreparationProgress(
                phase: .downloading, assetName: asset.displayName, completedBytes: completed, totalBytes: total))
            let verified = try await downloader.download(asset, in: cache) { update in
                switch update {
                case .downloading(let bytes):
                    progress(HaasModelPreparationProgress(
                        phase: .downloading, assetName: asset.displayName,
                        completedBytes: previousBytes + bytes, totalBytes: total))
                case .verifying:
                    progress(HaasModelPreparationProgress(
                        phase: .verifying, assetName: asset.displayName,
                        completedBytes: previousBytes + asset.byteCount, totalBytes: total))
                }
            }
            try Task.checkCancellation()
            try cache.recordVerification(verified, asset: asset)
            completed += asset.byteCount
        }
        try Task.checkCancellation()
        return try resolvedConfiguration(for: selection)
    }

    private func selectedConfiguration(_ selection: HaasRuntimeSelection) throws -> HaasRuntimeConfiguration {
        let bundled = HaasRuntimeConfiguration.bundled(directory: bundledDirectory)
        let configuration = HaasRuntimeConfiguration(
            executableURL: selectedURL(selection.executablePath) ?? bundled.executableURL,
            modelURL: selectedURL(selection.modelPath) ?? bundled.modelURL,
            vadModelURL: selectedURL(selection.vadModelPath) ?? bundled.vadModelURL)
        // Missing helpers and invalid explicit paths must fail before any model acquisition.
        try configuration.validateExecutable()
        if selectedURL(selection.modelPath) != nil { try HaasRuntimeConfiguration.validateReadableFile(configuration.modelURL) }
        if selectedURL(selection.vadModelPath) != nil { try HaasRuntimeConfiguration.validateReadableFile(configuration.vadModelURL) }
        return configuration
    }

    private func selectedURL(_ path: String) -> URL? {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private func defaultKinds(_ selection: HaasRuntimeSelection) -> Set<HaasModelAsset.Kind> {
        var kinds = Set<HaasModelAsset.Kind>()
        if selectedURL(selection.modelPath) == nil { kinds.insert(.recognition) }
        if selectedURL(selection.vadModelPath) == nil { kinds.insert(.vad) }
        return kinds
    }

    private func replacingDefaults(
        in configuration: HaasRuntimeConfiguration, locations: [HaasModelAsset.Kind: URL]
    ) -> HaasRuntimeConfiguration {
        HaasRuntimeConfiguration(
            executableURL: configuration.executableURL,
            modelURL: locations[.recognition] ?? configuration.modelURL,
            vadModelURL: locations[.vad] ?? configuration.vadModelURL)
    }

    private func verifyIfAvailable(_ url: URL, asset: HaasModelAsset) throws -> Bool {
        try Task.checkCancellation()
        if try cache.isVerified(url, asset: asset) { return true }
        let verified: HaasVerifiedModelFile
        do {
            if url == cache.modelURL(for: asset) {
                guard let cached = try cache.verifiedModel(asset) else { return false }
                verified = cached
            } else {
                guard FileManager.default.fileExists(atPath: url.path) else { return false }
                verified = HaasVerifiedModelFile(url: url, stamp: try HaasModelAssetFile.verify(url, asset: asset))
            }
        }
        catch HaasModelDownloadError.invalidSize { return false }
        catch HaasModelDownloadError.invalidChecksum { return false }
        try cache.recordVerification(verified, asset: asset)
        return true
    }
}
