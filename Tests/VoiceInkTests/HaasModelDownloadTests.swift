import Foundation
import XCTest
@testable import VoiceInk

final class HaasModelDownloadTests: XCTestCase {
    private let emptySelection = HaasRuntimeSelection(executablePath: "", modelPath: "", vadModelPath: "")

    func testMissingDefaultsAreVerifiedBeforePublicationAndReopenOffline() async throws {
        let fixture = try HaasModelAssetFixture()
        defer { fixture.cleanUp() }
        let progress = ProgressLog()
        let configuration = try await fixture.assets.prepare(emptySelection) { progress.append($0) }
        XCTAssertEqual(configuration.modelURL, fixture.cacheURL(.recognition))
        XCTAssertEqual(configuration.vadModelURL, fixture.cacheURL(.vad))
        XCTAssertEqual(try Data(contentsOf: configuration.modelURL), Data("abc".utf8))
        XCTAssertEqual(fixture.requestCount, 2)
        XCTAssertTrue(progress.values.contains { $0.phase == .downloading })
        XCTAssertTrue(progress.values.contains {
            $0.phase == .downloading && $0.assetName == "Haas-ja Q8" && $0.completedBytes > 0
        })
        XCTAssertTrue(progress.values.contains { $0.phase == .verifying })

        fixture.respond(.recognition, status: 503, body: Data())
        fixture.respond(.vad, status: 503, body: Data())
        let reopened = fixture.makeAssets()
        XCTAssertEqual(try reopened.resolvedConfiguration(for: emptySelection), configuration)
        let offline = try await reopened.prepare(emptySelection, downloadMissing: false)
        XCTAssertEqual(offline, configuration)
        XCTAssertEqual(fixture.requestCount, 2)
        XCTAssertTrue(fixture.partials.isEmpty)
        try Data("xyz".utf8).write(to: configuration.modelURL, options: .atomic)
        XCTAssertThrowsError(try reopened.resolvedConfiguration(for: emptySelection))
        do {
            _ = try await reopened.prepare(emptySelection, downloadMissing: false)
            XCTFail("A changed cache file must be verified again before becoming ready")
        } catch HaasModelDownloadError.missingModel {}
        XCTAssertEqual(fixture.requestCount, 2)
    }

    func testBundledAndExplicitModelsStayLocalAndInvalidExplicitPathDoesNotFallBack() async throws {
        let fixture = try HaasModelAssetFixture()
        defer { fixture.cleanUp() }
        for asset in fixture.manifest.assets {
            try Data("abc".utf8).write(to: fixture.bundle.appendingPathComponent(asset.filename))
        }
        let bundled = try await fixture.assets.prepare(emptySelection)
        XCTAssertEqual(bundled.modelURL, fixture.bundle.appendingPathComponent(HaasRuntimeConfiguration.modelFilename))
        let custom = fixture.root.appendingPathComponent("custom.gguf")
        try Data("user-selected model".utf8).write(to: custom)
        let selection = HaasRuntimeSelection(executablePath: "", modelPath: custom.path, vadModelPath: custom.path)
        let explicit = try await fixture.assets.prepare(selection)
        XCTAssertEqual(explicit.modelURL, custom)
        XCTAssertEqual(explicit.vadModelURL, custom)
        let invalid = HaasRuntimeSelection(executablePath: "", modelPath: custom.path + ".missing", vadModelPath: "")
        do {
            _ = try await fixture.assets.prepare(invalid)
            XCTFail("An invalid explicit path must not select the bundled model")
        } catch HaasRuntimeError.missingAsset(let path) {
            XCTAssertEqual(path, invalid.modelPath)
        }
        XCTAssertEqual(fixture.requestCount, 0)
    }

    func testAbsentHelperStopsPreparationBeforeManifestOrNetwork() async throws {
        let fixture = try HaasModelAssetFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.bundle.appendingPathComponent("speech"))
        try FileManager.default.removeItem(at: fixture.bundle.appendingPathComponent("manifest.json"))
        do {
            _ = try await fixture.assets.prepare(emptySelection)
            XCTFail("Missing helper must fail before downloading")
        } catch HaasRuntimeError.missingAsset(let path) {
            XCTAssertTrue(path.hasSuffix("/speech"))
        }
        XCTAssertEqual(fixture.requestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.path))
    }

    func testHTTPChecksumAndSizeFailuresPreserveExistingFileAndRemovePartials() async throws {
        for (status, body) in [(503, "abc"), (200, "xyz"), (200, "too long")] {
            let fixture = try HaasModelAssetFixture()
            defer { fixture.cleanUp() }
            let destination = fixture.cacheURL(.recognition)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old".utf8).write(to: destination)
            fixture.respond(.recognition, status: status, body: Data(body.utf8))
            do {
                _ = try await fixture.assets.prepare(emptySelection)
                XCTFail("An invalid download must not become ready")
            } catch is HaasModelDownloadError {}
            XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
            XCTAssertThrowsError(try fixture.assets.resolvedConfiguration(for: emptySelection))
            XCTAssertTrue(fixture.partials.isEmpty)
        }
    }

    func testCancellationCleansPartialAndAllowsExplicitRetry() async throws {
        let fixture = try HaasModelAssetFixture(largeModel: true)
        defer { fixture.cleanUp() }
        let began = expectation(description: "model bytes received")
        let received = ProgressLog()
        let modelBytes = Int64(fixture.modelBody.count)
        fixture.respond(.recognition, body: fixture.modelBody, chunkDelay: 0.02)
        let task = Task {
            try await fixture.assets.prepare(self.emptySelection) { progress in
                if progress.phase == .downloading, progress.completedBytes > 0, progress.completedBytes < modelBytes,
                    received.append(progress)
                { began.fulfill() }
            }
        }
        await fulfillment(of: [began], timeout: 3)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled preparation must not return ready")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as NSError).code == NSURLErrorCancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheURL(.recognition).path))
        XCTAssertTrue(fixture.partials.isEmpty)
        fixture.respond(.recognition, body: fixture.modelBody)
        let retried = try await fixture.assets.prepare(emptySelection)
        XCTAssertEqual(try Data(contentsOf: retried.modelURL), fixture.modelBody)
        XCTAssertEqual(fixture.requestCount, 3)
    }

    func testSingleFlightAndValidDestinationAvoidDuplicateDownloadsOrReplacement() async throws {
        let fixture = try HaasModelAssetFixture()
        defer { fixture.cleanUp() }
        let asset = try XCTUnwrap(fixture.manifest.assets.first { $0.kind == .recognition })
        fixture.respond(.recognition, body: Data("abc".utf8), chunkDelay: 0.05)
        let destination = fixture.cacheURL(.recognition)
        let cache = HaasModelCache(rootURL: fixture.cache)
        async let first = fixture.downloader.download(asset, in: cache) { _ in }
        async let second = fixture.downloader.download(asset, in: cache) { _ in }
        let results = try await (first, second)
        XCTAssertEqual(results.0, results.1)
        XCTAssertEqual(fixture.requestCount, 1)
        let before = try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date
        fixture.respond(.recognition, status: 503, body: Data())
        _ = try await fixture.downloader.download(asset, in: cache) { _ in }
        let after = try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testHTTPSDowngradeCannotPublishAnAsset() async throws {
        let fixture = try HaasModelAssetFixture()
        defer { fixture.cleanUp() }
        fixture.respond(.recognition, redirect: URL(string: "http://insecure.invalid/model")!)
        let request = Task { try await fixture.assets.prepare(self.emptySelection) }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            request.cancel()
        }
        defer { deadline.cancel() }
        let started = ContinuousClock.now
        var rejected = false
        do {
            _ = try await request.value
            XCTFail("HTTPS must not redirect to HTTP")
        } catch HaasModelDownloadError.insecureRedirect { rejected = true }
        catch { XCTFail("Expected an immediate insecure-redirect error; received \(error)") }
        XCTAssertTrue(rejected, "Reject the downgrade without waiting for the server's response body")
        XCTAssertLessThan(started.duration(to: .now), .seconds(1.5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheURL(.recognition).path))
        XCTAssertTrue(fixture.partials.isEmpty)
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testCacheSymlinksAreRejectedBeforeHTTPAndCannotChangeOutsideFiles() async throws {
        for kind in ["root", "hash", "verification", "model"] {
            let fixture = try HaasModelAssetFixture()
            defer { fixture.cleanUp() }
            let outside = fixture.root.appendingPathComponent("Outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let asset = try XCTUnwrap(fixture.manifest.assets.first { $0.kind == .recognition })
            let victim = outside.appendingPathComponent(asset.filename)
            try Data("old".utf8).write(to: victim)
            if kind != "root" { try FileManager.default.createDirectory(at: fixture.cache, withIntermediateDirectories: true) }
            let link: URL
            switch kind {
            case "root": link = fixture.cache
            case "hash": link = fixture.cacheURL(.recognition).deletingLastPathComponent()
            case "verification": link = fixture.cache.appendingPathComponent("Verified")
            default:
                link = fixture.cacheURL(.recognition)
                try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: kind == "model" ? victim : outside)
            do {
                _ = try await fixture.assets.prepare(emptySelection)
                XCTFail("Unexpected cache symlink accepted: \(kind)")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: victim), Data("old".utf8), kind)
            let outsideFiles = FileManager.default.enumerator(at: outside, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            XCTAssertEqual(outsideFiles.map { $0.resolvingSymlinksInPath() }, [victim.resolvingSymlinksInPath()], kind)
            XCTAssertEqual(fixture.requestCount, 0, kind)
        }
    }

    func testEmptyOrDirectoryHelpersFailBeforeHTTP() async throws {
        for kind in ["empty-executable", "directory-executable", "empty-library"] {
            let fixture = try HaasModelAssetFixture()
            defer { fixture.cleanUp() }
            let executable = fixture.bundle.appendingPathComponent("speech")
            if kind == "directory-executable" {
                try FileManager.default.removeItem(at: executable)
                try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: false)
            } else {
                let target = kind == "empty-library" ? fixture.bundle.appendingPathComponent("libspeech.3.dylib") : executable
                try Data().write(to: target)
            }
            let selection = HaasRuntimeSelection(executablePath: executable.path, modelPath: "", vadModelPath: "")
            do {
                _ = try await fixture.assets.prepare(selection)
                XCTFail("Invalid helper accepted: \(kind)")
            } catch HaasRuntimeError.missingAsset {}
            XCTAssertEqual(fixture.requestCount, 0, kind)
        }
    }

    func testVerifiedStampCannotCertifyASameSizeReplacement() async throws {
        let fixture = try HaasModelAssetFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.assets.prepare(emptySelection)
        let asset = try XCTUnwrap(fixture.manifest.assets.first { $0.kind == .recognition })
        let cache = HaasModelCache(rootURL: fixture.cache)
        let verified = try await fixture.downloader.download(asset, in: cache) { _ in }
        try Data("xyz".utf8).write(to: verified.url, options: .atomic)
        XCTAssertThrowsError(try cache.recordVerification(verified, asset: asset)) { error in
            guard case HaasModelDownloadError.changedDuringVerification = error else {
                return XCTFail("Expected a changed file identity, received \(error)")
            }
        }
        XCTAssertFalse(try cache.isVerified(verified.url, asset: asset))
        XCTAssertThrowsError(try fixture.assets.resolvedConfiguration(for: emptySelection))
        XCTAssertEqual(fixture.requestCount, 2)
    }

    func testOSAncestorAliasesWorkButReceiptLeafSymlinksAreRejected() async throws {
        let fixture = try HaasModelAssetFixture()
        defer { fixture.cleanUp() }
        let aliasPath = fixture.cache.resolvingSymlinksInPath().path
            .replacingOccurrences(of: "/private/var/", with: "/var/")
        let assets = HaasModelAssets(
            bundledDirectory: fixture.bundle, cacheDirectory: URL(fileURLWithPath: aliasPath), downloader: fixture.downloader)
        let configuration = try await assets.prepare(emptySelection)
        XCTAssertEqual(try assets.resolvedConfiguration(for: emptySelection), configuration)
        let files = FileManager.default.enumerator(at: fixture.cache, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        let receipt = try XCTUnwrap(files.first { $0.pathExtension == "json" })
        let victim = fixture.root.appendingPathComponent("outside-receipt.json")
        try Data("old".utf8).write(to: victim)
        try FileManager.default.removeItem(at: receipt)
        try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: victim)
        XCTAssertThrowsError(try assets.resolvedConfiguration(for: emptySelection))
        do {
            _ = try await assets.prepare(emptySelection)
            XCTFail("A receipt symlink must not be read or replaced")
        } catch HaasModelDownloadError.unsafeCachePath {}
        XCTAssertEqual(try Data(contentsOf: victim), Data("old".utf8))
        XCTAssertEqual(fixture.requestCount, 2)
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [HaasModelPreparationProgress] = []
        var values: [HaasModelPreparationProgress] { lock.withLock { stored } }
        @discardableResult
        func append(_ value: HaasModelPreparationProgress) -> Bool {
            lock.withLock {
                let first = stored.isEmpty
                stored.append(value)
                return first
            }
        }
    }

}
