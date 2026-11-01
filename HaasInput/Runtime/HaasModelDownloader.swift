import Foundation

actor HaasModelDownloader {
    enum Progress: Sendable { case downloading(Int64), verifying }
    private struct Job {
        let id: UUID
        let task: Task<HaasVerifiedModelFile, Error>
    }
    private let session: URLSession
    private var jobs: [URL: Job] = [:]

    init(session: URLSession) { self.session = session }

    func download(
        _ asset: HaasModelAsset, in cache: HaasModelCache,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> HaasVerifiedModelFile {
        let destination = cache.modelURL(for: asset)
        if let job = jobs[destination] { return try await wait(for: job.task) }
        let id = UUID()
        let session = session
        let task = Task.detached(priority: .utility) {
            try await Self.transfer(asset, cache: cache, session: session, progress: progress)
        }
        jobs[destination] = Job(id: id, task: task)
        defer { if jobs[destination]?.id == id { jobs.removeValue(forKey: destination) } }
        return try await wait(for: task)
    }

    private func wait(for task: Task<HaasVerifiedModelFile, Error>) async throws -> HaasVerifiedModelFile {
        try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }

    private static func transfer(
        _ asset: HaasModelAsset, cache: HaasModelCache, session: URLSession,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> HaasVerifiedModelFile {
        try Task.checkCancellation()
        guard asset.sourceURL.scheme == "https" else { throw HaasModelDownloadError.insecureRedirect }
        try cache.validateStorage(for: asset, receiptSources: [cache.modelURL(for: asset)])
        if let existing = try verifiedExisting(asset, cache: cache) { return existing }
        try Task.checkCancellation()
        let delegate = DownloadDelegate(expectedBytes: asset.byteCount) { progress(.downloading($0)) }
        var request = URLRequest(url: asset.sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let input = try await delegate.download(request, session: session)
        defer { try? input.close() }
        try Task.checkCancellation()
        progress(.verifying)
        guard try HaasModelAssetFile.Stamp(descriptor: input.fileDescriptor).size == asset.byteCount else {
            throw HaasModelDownloadError.invalidSize(asset.displayName)
        }
        let output = try cache.beginModelWrite(asset)
        var copied: Int64 = 0
        while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            copied += Int64(chunk.count)
            guard copied <= asset.byteCount else { throw HaasModelDownloadError.invalidSize(asset.displayName) }
            try output.write(chunk)
        }
        let stamp = try HaasModelAssetFile.verify(output.file, asset: asset)
        try Task.checkCancellation()
        if let existing = try verifiedExisting(asset, cache: cache) { return existing }
        return try cache.publishedModel(output, asset: asset, stamp: stamp)
    }

    private static func verifiedExisting(_ asset: HaasModelAsset, cache: HaasModelCache) throws -> HaasVerifiedModelFile? {
        do { return try cache.verifiedModel(asset) }
        catch HaasModelDownloadError.invalidSize { return nil }
        catch HaasModelDownloadError.invalidChecksum { return nil }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let expectedBytes: Int64
        let progress: @Sendable (Int64) -> Void
        private let lock = NSLock()
        private var storedError: Error?
        private var lastProgress = ContinuousClock.now
        private var continuation: CheckedContinuation<FileHandle, Error>?
        private var task: URLSessionDownloadTask?
        private var cancelled = false
        private var receivedFile: FileHandle?

        init(expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) {
            self.expectedBytes = expectedBytes
            self.progress = progress
        }

        func download(_ request: URLRequest, session: URLSession) async throws -> FileHandle {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    let download = session.downloadTask(with: request)
                    download.delegate = self
                    let start = lock.withLock {
                        guard !cancelled else { return false }
                        self.continuation = continuation
                        task = download
                        return true
                    }
                    if start { download.resume() }
                    else {
                        download.cancel()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                let task = self.lock.withLock {
                    self.cancelled = true
                    return self.task
                }
                task?.cancel()
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard request.url?.scheme == "https", request.url?.user == nil, request.url?.password == nil else {
                lock.withLock { storedError = HaasModelDownloadError.insecureRedirect }
                completionHandler(nil)
                task.cancel()
                return
            }
            completionHandler(request)
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            if totalBytesWritten > expectedBytes {
                lock.withLock { storedError = HaasModelDownloadError.invalidSize("モデル") }
                downloadTask.cancel()
            } else {
                let shouldReport = lock.withLock {
                    let now = ContinuousClock.now
                    guard totalBytesWritten == expectedBytes || lastProgress.duration(to: now) >= .milliseconds(100) else {
                        return false
                    }
                    lastProgress = now
                    return true
                }
                if shouldReport { progress(totalBytesWritten) }
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // Retain an open descriptor before URLSession removes its temporary pathname.
            // https://developer.apple.com/documentation/foundation/urlsessiondownloaddelegate
            do {
                if lock.withLock({ cancelled }) { throw CancellationError() }
                guard let response = downloadTask.response as? HTTPURLResponse else {
                    throw HaasModelDownloadError.httpStatus(0)
                }
                guard response.statusCode == 200 else { throw HaasModelDownloadError.httpStatus(response.statusCode) }
                guard response.url?.scheme == "https" else { throw HaasModelDownloadError.insecureRedirect }
                let file = try HaasModelAssetFile.openReadableFile(location)
                lock.withLock { receivedFile = file }
            } catch {
                lock.withLock { if storedError == nil { storedError = error } }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let completion = lock.withLock { () -> (CheckedContinuation<FileHandle, Error>?, FileHandle?, Error?) in
                let resultError = cancelled ? CancellationError() : storedError ?? error
                    ?? (receivedFile != nil ? nil : URLError(.badServerResponse))
                let pending = continuation
                continuation = nil
                self.task = nil
                let file = receivedFile
                receivedFile = nil
                return (pending, file, resultError)
            }
            if let error = completion.2 {
                try? completion.1?.close()
                completion.0?.resume(throwing: error)
            } else if let file = completion.1 { completion.0?.resume(returning: file) }
        }
    }
}
