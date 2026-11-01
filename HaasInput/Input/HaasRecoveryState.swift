import Foundation

struct HaasRecoveryRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date?
    var transcriptionID: UUID?
    var ledger: HaasSegmentLedger
    var message: String

    init(
        id: UUID,
        createdAt: Date?,
        transcriptionID: UUID? = nil,
        ledger: HaasSegmentLedger = HaasSegmentLedger(),
        message: String = ""
    ) {
        self.id = id
        self.createdAt = createdAt
        self.transcriptionID = transcriptionID
        self.ledger = ledger
        self.message = message
    }
}

struct HaasRecoveryState: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    var active: HaasRecoveryRecord?
    var archives: [HaasRecoveryRecord]
    var legacyMigrationFingerprint: String?

    init(
        active: HaasRecoveryRecord? = nil,
        archives: [HaasRecoveryRecord] = [],
        legacyMigrationFingerprint: String? = nil
    ) {
        version = Self.currentVersion
        self.active = active
        self.archives = archives
        self.legacyMigrationFingerprint = legacyMigrationFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case version, active, archives, legacyMigrationFingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw HaasRecoveryError.unsupportedVersion(version)
        }
        active = try container.decodeIfPresent(HaasRecoveryRecord.self, forKey: .active)
        archives = try container.decode([HaasRecoveryRecord].self, forKey: .archives)
        legacyMigrationFingerprint = try container.decodeIfPresent(String.self, forKey: .legacyMigrationFingerprint)
    }
}

enum HaasRecoveryError: LocalizedError {
    case loadRequired
    case unsupportedVersion(Int)
    case unreadableState
    case unreadableLegacy
    case invalidState
    case storageChanged
    case legacyChanged
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .loadRequired:
            return "入力確認待ちの保存状態を確認できていません。保留文をコピーしてからアプリを再起動してください。"
        case .unsupportedVersion(let version):
            return "入力確認待ちの保存形式 (版 \(version)) に対応していません。保存データは変更していません。"
        case .unreadableState:
            return "入力確認待ちの保存データを読み込めません。元のファイルは保持しています。"
        case .unreadableLegacy:
            return "以前の保留データを読み込めません。元のデータは保持しています。"
        case .invalidState:
            return "入力確認待ちの内容に不整合があるため保存できません。保留文はコピーして保管してください。"
        case .storageChanged:
            return "入力確認待ちの保存ファイルが変更されています。上書きせずに処理を停止しました。"
        case .legacyChanged:
            return "以前の保留データが移行時の内容と異なります。上書きや削除をせずに処理を停止しました。"
        case .verificationFailed:
            return "入力確認待ちの保存結果を確認できません。保存済みファイルと以前の保留データは保持しています。"
        }
    }
}
