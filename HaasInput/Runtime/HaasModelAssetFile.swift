import CryptoKit
import Darwin
import Foundation

struct HaasVerifiedModelFile: Equatable, Sendable {
    let url: URL
    let stamp: HaasModelAssetFile.Stamp
}

enum HaasModelAssetFile {
    struct Stamp: Codable, Equatable, Sendable {
        let size: Int64
        let inode: UInt64
        let device: UInt64
        let modified: Date

        init(url: URL) throws {
            let file = try HaasModelAssetFile.openReadableFile(url)
            defer { try? file.close() }
            try self.init(descriptor: file.fileDescriptor)
        }

        init(descriptor: Int32) throws {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw HaasModelDownloadError.changedDuringVerification
            }
            size = info.st_size
            inode = info.st_ino
            device = UInt64(bitPattern: Int64(info.st_dev))
            modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        }
    }

    static func openReadableFile(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { _ = try Stamp(descriptor: descriptor) }
        catch { try? file.close(); throw error }
        return file
    }

    static func verify(_ url: URL, asset: HaasModelAsset) throws -> Stamp {
        let file = try openReadableFile(url)
        defer { try? file.close() }
        return try verify(file, asset: asset)
    }

    static func verify(_ file: FileHandle, asset: HaasModelAsset) throws -> Stamp {
        try Task.checkCancellation()
        let before = try Stamp(descriptor: file.fileDescriptor)
        guard before.size == asset.byteCount else { throw HaasModelDownloadError.invalidSize(asset.displayName) }
        try file.seek(toOffset: 0)
        var checksum = SHA256()
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            checksum.update(data: chunk)
        }
        guard try Stamp(descriptor: file.fileDescriptor) == before else { throw HaasModelDownloadError.changedDuringVerification }
        let digest = checksum.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256 else { throw HaasModelDownloadError.invalidChecksum(asset.displayName) }
        return before
    }

    static func pathKey(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
