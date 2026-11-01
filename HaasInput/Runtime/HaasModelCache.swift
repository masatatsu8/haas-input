import Darwin
import Foundation

struct HaasModelCache: Sendable {
    let rootURL: URL

    func modelURL(for asset: HaasModelAsset) -> URL {
        rootURL.appendingPathComponent(asset.sha256, isDirectory: true).appendingPathComponent(asset.filename)
    }

    func validateStorage(for asset: HaasModelAsset, receiptSources: [URL]) throws {
        try validateLeaf([asset.sha256, asset.filename])
        for source in receiptSources { try validateLeaf(receiptComponents(source, asset: asset)) }
    }

    func verifiedModel(_ asset: HaasModelAsset) throws -> HaasVerifiedModelFile? {
        guard let directory = try directory([asset.sha256], create: false),
            let file = try directory.openFile(asset.filename)
        else { return nil }
        defer { try? file.close() }
        return HaasVerifiedModelFile(url: modelURL(for: asset), stamp: try HaasModelAssetFile.verify(file, asset: asset))
    }

    func isVerified(_ url: URL, asset: HaasModelAsset) throws -> Bool {
        let components = receiptComponents(url, asset: asset)
        guard let directory = try directory(Array(components.dropLast()), create: false),
            let file = try directory.openFile(components.last!)
        else { return false }
        defer { try? file.close() }
        guard try HaasModelAssetFile.Stamp(descriptor: file.fileDescriptor).size <= 8_192,
            let data = try file.read(upToCount: 8_193), data.count <= 8_192,
            let receipt = try? JSONDecoder().decode(Verification.self, from: data), receipt.sha256 == asset.sha256,
            let current = try currentStamp(url, asset: asset)
        else { return false }
        return current.size == asset.byteCount && current == receipt.stamp
    }

    func recordVerification(_ verified: HaasVerifiedModelFile, asset: HaasModelAsset) throws {
        guard verified.stamp.size == asset.byteCount,
            try currentStamp(verified.url, asset: asset) == verified.stamp
        else { throw HaasModelDownloadError.changedDuringVerification }
        let data = try JSONEncoder().encode(Verification(sha256: asset.sha256, stamp: verified.stamp))
        let components = receiptComponents(verified.url, asset: asset)
        let write = try beginWrite(components)
        try write.write(data)
        try write.publish()
        guard try currentStamp(verified.url, asset: asset) == verified.stamp else {
            throw HaasModelDownloadError.changedDuringVerification
        }
    }

    func beginModelWrite(_ asset: HaasModelAsset) throws -> Write {
        try beginWrite([asset.sha256, asset.filename])
    }

    func publishedModel(_ write: Write, asset: HaasModelAsset, stamp: HaasModelAssetFile.Stamp) throws -> HaasVerifiedModelFile {
        guard try HaasModelAssetFile.Stamp(descriptor: write.file.fileDescriptor) == stamp else {
            throw HaasModelDownloadError.changedDuringVerification
        }
        try write.publish()
        let url = modelURL(for: asset)
        guard try currentStamp(url, asset: asset) == stamp else { throw HaasModelDownloadError.changedDuringVerification }
        return HaasVerifiedModelFile(url: url, stamp: stamp)
    }

    private struct Verification: Codable {
        let sha256: String
        let stamp: HaasModelAssetFile.Stamp
    }

    private func receiptComponents(_ url: URL, asset: HaasModelAsset) -> [String] {
        ["Verified", asset.sha256, HaasModelAssetFile.pathKey(url) + ".json"]
    }

    private func currentStamp(_ url: URL, asset: HaasModelAsset) throws -> HaasModelAssetFile.Stamp? {
        if url == modelURL(for: asset) {
            guard let directory = try directory([asset.sha256], create: false),
                let file = try directory.openFile(asset.filename)
            else { return nil }
            defer { try? file.close() }
            return try HaasModelAssetFile.Stamp(descriptor: file.fileDescriptor)
        }
        return try? HaasModelAssetFile.Stamp(url: url)
    }

    private func validateLeaf(_ components: [String]) throws {
        guard let directory = try directory(Array(components.dropLast()), create: false) else { return }
        try directory.validateFile(components.last!)
    }

    private func beginWrite(_ components: [String]) throws -> Write {
        guard let directory = try directory(Array(components.dropLast()), create: true) else {
            throw HaasModelDownloadError.unsafeCachePath(rootURL.path)
        }
        return try Write(directory: directory, destination: components.last!)
    }

    private func directory(_ components: [String], create: Bool) throws -> Directory? {
        // Resolve OS aliases above the owned root; no owned component is followed through a link.
        let parent = rootURL.deletingLastPathComponent().resolvingSymlinksInPath()
        if create { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT, !create { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var directory = Directory(descriptor: descriptor, path: parent.path)
        for component in [rootURL.lastPathComponent] + components {
            guard let child = try directory.openDirectory(component, create: create) else { return nil }
            directory = child
        }
        return directory
    }

    final class Write {
        let file: FileHandle
        private let directory: Directory
        private let temporary: String
        private let destination: String

        fileprivate init(directory: Directory, destination: String) throws {
            try directory.validateFile(destination)
            self.directory = directory
            self.destination = destination
            temporary = ".\(destination).\(UUID().uuidString).partial"
            let descriptor = openat(directory.descriptor, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }

        deinit {
            try? file.close()
            unlinkat(directory.descriptor, temporary, 0)
        }

        func write(_ data: Data) throws {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let written = Darwin.write(file.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += written
                }
            }
        }

        fileprivate func publish() throws {
            try Task.checkCancellation()
            try file.synchronize()
            try directory.validateFile(destination)
            guard let source = try directory.openFile(temporary) else { throw HaasModelDownloadError.changedDuringVerification }
            defer { try? source.close() }
            guard try HaasModelAssetFile.Stamp(descriptor: source.fileDescriptor)
                == HaasModelAssetFile.Stamp(descriptor: file.fileDescriptor)
            else { throw HaasModelDownloadError.changedDuringVerification }
            guard renameat(directory.descriptor, temporary, directory.descriptor, destination) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    fileprivate final class Directory {
        let descriptor: Int32
        let path: String
        init(descriptor: Int32, path: String) { self.descriptor = descriptor; self.path = path }
        deinit { close(descriptor) }

        func openDirectory(_ name: String, create: Bool) throws -> Directory? {
            try validateName(name)
            var child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child < 0, errno == ENOENT, create {
                guard mkdirat(descriptor, name, 0o700) == 0 || errno == EEXIST else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else {
                if errno == ENOENT, !create { return nil }
                throw HaasModelDownloadError.unsafeCachePath(path + "/" + name)
            }
            return Directory(descriptor: child, path: path + "/" + name)
        }

        func validateFile(_ name: String) throws {
            try validateName(name)
            var info = stat()
            if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw HaasModelDownloadError.unsafeCachePath(path + "/" + name)
            }
        }

        func openFile(_ name: String) throws -> FileHandle? {
            try validateFile(name)
            let fd = openat(descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else {
                if errno == ENOENT { return nil }
                throw HaasModelDownloadError.unsafeCachePath(path + "/" + name)
            }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do { _ = try HaasModelAssetFile.Stamp(descriptor: fd) }
            catch { try? file.close(); throw error }
            return file
        }

        private func validateName(_ name: String) throws {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                throw HaasModelDownloadError.unsafeCachePath(path)
            }
        }
    }
}
