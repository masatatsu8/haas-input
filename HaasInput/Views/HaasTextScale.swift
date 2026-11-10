import AppKit
import SwiftUI

/// 文字の大きさの設定。値は百分率
enum HaasTextScale: Int, CaseIterable, Identifiable {
    case smaller = 85, standard = 100, large = 115, larger = 130, largest = 150, huge = 175

    var id: Int { rawValue }

    var factor: CGFloat { CGFloat(rawValue) / 100 }

    var displayName: String {
        self == .standard ? "100% (標準)" : "\(rawValue)%"
    }

    var controlSize: ControlSize {
        switch self {
        case .smaller: .small
        case .standard, .large: .regular
        case .larger, .largest, .huge: .large
        }
    }

    /// 保存した値。キーがない・知らない値なら .standard
    static func stored(forKey key: String, in defaults: UserDefaults = .standard) -> HaasTextScale {
        guard let raw = defaults.object(forKey: key) as? Int else { return .standard }
        return HaasTextScale(rawValue: raw) ?? .standard
    }
}

enum HaasTextScaleSettingsKeys {
    static let mainWindow = "HaasMainWindowTextScale"
}

private struct HaasTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// 文字の倍率。既定は 1
    var haasTextScale: CGFloat {
        get { self[HaasTextScaleKey.self] }
        set { self[HaasTextScaleKey.self] = newValue }
    }
}

enum HaasFont {
    /// macOS の文字の種類ごとの標準の大きさ (pt)
    static func pointSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
    }

    /// macOS の文字の種類ごとの標準の太さ。headline は bold、caption2 は medium
    static func defaultWeight(for style: Font.TextStyle) -> Font.Weight {
        switch style {
        case .headline: .bold
        case .caption2: .medium
        default: .regular
        }
    }

    /// style の標準の大きさ × scale の system フォント。weight の指定がなければ style の標準の太さ
    static func font(_ style: Font.TextStyle, scale: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        .system(size: pointSize(for: style) * scale, weight: weight ?? defaultWeight(for: style), design: design ?? .default)
    }
}

private struct HaasFontModifier: ViewModifier {
    @Environment(\.haasTextScale) private var scale
    let style: Font.TextStyle?
    let size: CGFloat
    let weight: Font.Weight?
    let design: Font.Design?

    func body(content: Content) -> some View {
        if let style {
            content.font(HaasFont.font(style, scale: scale, weight: weight, design: design))
        } else {
            content.font(.system(size: size * scale, weight: weight ?? .regular, design: design ?? .default))
        }
    }
}

extension View {
    /// 環境の haasTextScale を読んで .font を当てる
    func haasFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(HaasFontModifier(style: style, size: 0, weight: weight, design: design))
    }

    func haasFont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(HaasFontModifier(style: nil, size: size, weight: weight, design: design))
    }

    /// 大きさの決まった sheet に付ける。倍率を掛け、画面の使える範囲に収める
    func haasSheetFrame(width: CGFloat, height: CGFloat, scale: CGFloat) -> some View {
        let visible = NSScreen.main?.visibleFrame.size
        return frame(
            width: min(width * scale, (visible?.width ?? .infinity) * 0.9),
            height: min(height * scale, (visible?.height ?? .infinity) * 0.85))
    }

    /// 窓の根や sheet の中身に付ける。haasTextScale、本文の既定の .font (body × 倍率)、controlSize をまとめて当てる
    func haasTextScaleRoot(_ scale: HaasTextScale) -> some View {
        environment(\.haasTextScale, scale.factor)
            .font(HaasFont.font(.body, scale: scale.factor))
            .controlSize(scale.controlSize)
    }
}
