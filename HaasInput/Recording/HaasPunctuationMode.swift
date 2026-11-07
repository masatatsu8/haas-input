import Foundation

enum HaasPunctuationMode: String, CaseIterable {
    case fast
    case natural
    case proofread

    static let settingsKey = "HaasPunctuationMode"

    static var stored: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: settingsKey) ?? "") ?? .fast
    }

    var displayName: String {
        switch self {
        case .fast: "速度優先"
        case .natural: "自然さ優先"
        case .proofread: "誤字も修正"
        }
    }

    var description: String {
        switch self {
        case .fast:
            "追加のAIを使わず、明確な文末にだけ「。」または「？」を補います。"
        case .natural:
            "Appleの端末内AIで「、」「。」「？」を補います。語句が変わった場合や処理が間に合わない場合は、原文を入力します。"
        case .proofread:
            "Appleの端末内AIで「、」「。」「？」を補い、明らかな誤変換も直します。文章が大きく変わった場合や処理が間に合わない場合は、原文を入力します。"
        }
    }

    var usesOnDeviceModel: Bool {
        switch self {
        case .fast: false
        case .natural, .proofread: true
        }
    }
}
