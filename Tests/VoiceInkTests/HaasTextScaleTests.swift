import SwiftUI
import XCTest
@testable import VoiceInk

final class HaasTextScaleTests: XCTestCase {
    func testFactorAndDisplayName() {
        XCTAssertEqual(HaasTextScale.smaller.factor, 0.85, accuracy: 0.0001)
        XCTAssertEqual(HaasTextScale.standard.factor, 1, accuracy: 0.0001)
        XCTAssertEqual(HaasTextScale.huge.factor, 1.75, accuracy: 0.0001)
        XCTAssertEqual(HaasTextScale.standard.displayName, "100% (標準)")
        XCTAssertEqual(HaasTextScale.smaller.displayName, "85%")
        XCTAssertEqual(HaasTextScale.largest.displayName, "150%")
    }

    func testControlSize() {
        XCTAssertEqual(HaasTextScale.smaller.controlSize, .small)
        XCTAssertEqual(HaasTextScale.standard.controlSize, .regular)
        XCTAssertEqual(HaasTextScale.large.controlSize, .regular)
        XCTAssertEqual(HaasTextScale.larger.controlSize, .large)
        XCTAssertEqual(HaasTextScale.huge.controlSize, .large)
    }

    func testPointSizeTable() {
        XCTAssertEqual(HaasFont.pointSize(for: .largeTitle), 26)
        XCTAssertEqual(HaasFont.pointSize(for: .title), 22)
        XCTAssertEqual(HaasFont.pointSize(for: .title2), 17)
        XCTAssertEqual(HaasFont.pointSize(for: .title3), 15)
        XCTAssertEqual(HaasFont.pointSize(for: .headline), 13)
        XCTAssertEqual(HaasFont.pointSize(for: .body), 13)
        XCTAssertEqual(HaasFont.pointSize(for: .callout), 12)
        XCTAssertEqual(HaasFont.pointSize(for: .subheadline), 11)
        XCTAssertEqual(HaasFont.pointSize(for: .footnote), 10)
        XCTAssertEqual(HaasFont.pointSize(for: .caption), 10)
        XCTAssertEqual(HaasFont.pointSize(for: .caption2), 10)
    }

    func testDefaultWeightMatchesMacOS() {
        XCTAssertEqual(HaasFont.defaultWeight(for: .headline), .bold)
        XCTAssertEqual(HaasFont.defaultWeight(for: .caption2), .medium)
        XCTAssertEqual(HaasFont.defaultWeight(for: .caption), .regular)
        XCTAssertEqual(HaasFont.defaultWeight(for: .body), .regular)
    }

    func testStoredFallsBackToStandard() throws {
        let suite = "HaasTextScaleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = HaasTextScaleSettingsKeys.mainWindow

        XCTAssertEqual(HaasTextScale.stored(forKey: key, in: defaults), .standard)
        defaults.set(42, forKey: key)
        XCTAssertEqual(HaasTextScale.stored(forKey: key, in: defaults), .standard)
        defaults.set(0, forKey: key)
        XCTAssertEqual(HaasTextScale.stored(forKey: key, in: defaults), .standard)
        defaults.set(130, forKey: key)
        XCTAssertEqual(HaasTextScale.stored(forKey: key, in: defaults), .larger)
    }
}
