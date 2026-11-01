import CryptoKit
import Foundation

@MainActor
final class HaasRecoveryStore {
    private static let legacyStorageKey = "HaasPendingInput.v1"

    private let fileURL: URL
    private let legacyDefaults: UserDefaults
    private var didLoad = false
    private var loadedFileData: Data?
    private var loadedLegacyData: Data?
    private var migrationFingerprint: String?

    init(fileURL: URL? = nil, legacyDefaults: UserDefaults = .standard) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppStorageIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("haas-input-recovery.json")
        self.legacyDefaults = legacyDefaults
    }

    func load() throws -> HaasRecoveryState {
        didLoad = false
        let fileData = try readFileIfPresent()
        var state = try fileData.map(Self.decodeState) ?? HaasRecoveryState()
        let legacyData = try readLegacyData()

        if let legacyData {
            let fingerprint = Self.fingerprint(of: legacyData)
            if fileData != nil {
                guard state.legacyMigrationFingerprint == fingerprint else {
                    throw HaasRecoveryError.legacyChanged
                }
            } else {
                let ledger: HaasSegmentLedger
                do {
                    ledger = try JSONDecoder().decode(HaasSegmentLedger.self, from: legacyData)
                    try Self.validateLedger(ledger)
                } catch {
                    throw HaasRecoveryError.unreadableLegacy
                }
                let archive = ledger.unresolvedArchive
                if archive.hasUnresolvedSegments {
                    state.archives.append(HaasRecoveryRecord(
                        id: UUID(),
                        createdAt: nil,
                        ledger: archive,
                        message: "以前の録音から移行した入力確認待ちです。録音日時は不明です。"
                    ))
                }
                state.legacyMigrationFingerprint = fingerprint
            }
        }

        state.active?.ledger.recoverInterruptedPaste()
        try Self.validateState(state)
        loadedFileData = fileData
        loadedLegacyData = legacyData
        migrationFingerprint = state.legacyMigrationFingerprint
        didLoad = true
        return state
    }

    func save(_ candidate: HaasRecoveryState) throws {
        guard didLoad else { throw HaasRecoveryError.loadRequired }
        try Self.validateState(candidate)
        guard candidate.legacyMigrationFingerprint == migrationFingerprint else {
            throw HaasRecoveryError.invalidState
        }
        guard try readFileIfPresent() == loadedFileData else {
            didLoad = false
            throw HaasRecoveryError.storageChanged
        }
        guard try readLegacyData() == loadedLegacyData else {
            didLoad = false
            throw HaasRecoveryError.legacyChanged
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(candidate)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)

        do {
            let persisted = try Data(contentsOf: fileURL)
            guard persisted == data, try Self.decodeState(persisted) == candidate else {
                throw HaasRecoveryError.verificationFailed
            }
        } catch {
            // The atomic replacement may already have committed. Do not overwrite it with an older snapshot.
            didLoad = false
            throw HaasRecoveryError.verificationFailed
        }

        loadedFileData = data
        if let loadedLegacyData {
            guard try readLegacyData() == loadedLegacyData else {
                didLoad = false
                throw HaasRecoveryError.legacyChanged
            }
            legacyDefaults.removeObject(forKey: Self.legacyStorageKey)
            do {
                let remaining = try readLegacyData()
                guard remaining == nil || remaining == loadedLegacyData else {
                    throw HaasRecoveryError.legacyChanged
                }
                self.loadedLegacyData = remaining
            } catch {
                didLoad = false
                throw error
            }
        }
    }

    private func readFileIfPresent() throws -> Data? {
        do {
            return try Data(contentsOf: fileURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            return nil
        }
    }

    private func readLegacyData() throws -> Data? {
        guard let value = legacyDefaults.object(forKey: Self.legacyStorageKey) else { return nil }
        guard let data = value as? Data else { throw HaasRecoveryError.unreadableLegacy }
        return data
    }

    private static func decodeState(_ data: Data) throws -> HaasRecoveryState {
        do {
            let state = try JSONDecoder().decode(HaasRecoveryState.self, from: data)
            try validateState(state)
            return state
        } catch let error as HaasRecoveryError {
            throw error
        } catch {
            throw HaasRecoveryError.unreadableState
        }
    }

    private static func validateState(_ state: HaasRecoveryState) throws {
        guard state.version == HaasRecoveryState.currentVersion else {
            throw HaasRecoveryError.unsupportedVersion(state.version)
        }
        if let fingerprint = state.legacyMigrationFingerprint {
            guard fingerprint.count == 64,
                fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw HaasRecoveryError.invalidState }
        }
        var ids = Set<UUID>()
        for record in state.archives + (state.active.map { [$0] } ?? []) {
            guard ids.insert(record.id).inserted,
                record.createdAt?.timeIntervalSinceReferenceDate.isFinite != false
            else { throw HaasRecoveryError.invalidState }
            try validateLedger(record.ledger)
        }
        for archive in state.archives {
            guard archive.ledger.hasUnresolvedSegments,
                archive.ledger.segments.allSatisfy({ [.pending, .uncertain].contains($0.disposition) })
            else { throw HaasRecoveryError.invalidState }
        }
    }

    private static func validateLedger(_ ledger: HaasSegmentLedger) throws {
        var ids = Set<String>()
        for segment in ledger.segments {
            guard !segment.id.isEmpty, !segment.text.isEmpty, ids.insert(segment.id).inserted else {
                throw HaasRecoveryError.invalidState
            }
        }
    }

    private static func fingerprint(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
