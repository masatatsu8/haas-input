import Foundation

enum HaasPunctuationMode: String, CaseIterable {
    case fast
    case natural

    static let settingsKey = "HaasPunctuationMode"

    static var stored: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: settingsKey) ?? "") ?? .fast
    }

    var displayName: String {
        switch self {
        case .fast: "速度優先"
        case .natural: "自然さ優先"
        }
    }

    var description: String {
        switch self {
        case .fast:
            "追加のAIを使わず、明確な文末にだけ「。」を補います。"
        case .natural:
            "Appleの端末内AIで「、」「。」を補います。語句が変わった場合や処理が間に合わない場合は、原文を入力します。"
        }
    }
}
