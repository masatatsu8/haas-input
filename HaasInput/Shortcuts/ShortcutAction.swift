import Foundation

enum ShortcutAction: Hashable, Sendable {
    case primaryRecording
    case secondaryRecording
    case pasteLastTranscription
    case cancelRecorder
    case openQuickHistory
    case recorderPanelEscape
    case correctLastInput

    var userDefaultsKey: String { "Shortcut_\(storageName)" }
    var isStored: Bool { self != .recorderPanelEscape }

    var storageName: String {
        switch self {
        case .primaryRecording: return "primaryRecording"
        case .secondaryRecording: return "secondaryRecording"
        case .pasteLastTranscription: return "pasteLastTranscription"
        case .cancelRecorder: return "cancelRecorder"
        case .openQuickHistory: return "openHistoryWindow"
        case .recorderPanelEscape: return "recorderPanelEscape"
        case .correctLastInput: return "correctLastInput"
        }
    }

    var displayName: String {
        switch self {
        case .primaryRecording: return "録音ショートカット"
        case .secondaryRecording: return "2つ目の録音ショートカット"
        case .pasteLastTranscription: return "直前の認識結果を入力"
        case .cancelRecorder: return "録音を取り消す"
        case .openQuickHistory: return "履歴を開く"
        case .recorderPanelEscape: return "録音パネルの取消"
        case .correctLastInput: return "直前の入力を直す"
        }
    }

    static let globalUtilityActions: [Self] = [.pasteLastTranscription, .openQuickHistory, .correctLastInput]
    static let recorderPanelStoredActions: [Self] = [.cancelRecorder]
    static let legacyKeyboardShortcutActions: [Self] = [
        .primaryRecording, .secondaryRecording, .pasteLastTranscription, .cancelRecorder, .openQuickHistory,
        .correctLastInput,
    ]
}
