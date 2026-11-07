import XCTest
@testable import VoiceInk

final class HaasFieldStateTests: XCTestCase {
    func testCaretBeforeTrailingTextKeepsEmojiSequenceIntact() {
        let value = "前の文👩‍💻合って"
        let caret = ("前の文👩‍💻" as NSString).length
        let state = HaasFieldState.make(value: value, selectedRange: CFRange(location: caret, length: 0))
        XCTAssertEqual(state, .readable(textBeforeCaret: "前の文👩‍💻", selectionLength: 0))
    }

    func testSelectionLengthIsReported() {
        let state = HaasFieldState.make(value: "abcdef", selectedRange: CFRange(location: 2, length: 3))
        XCTAssertEqual(state, .readable(textBeforeCaret: "ab", selectionLength: 3))
    }

    func testRangeBeyondValueIsUnreadable() {
        XCTAssertEqual(
            HaasFieldState.make(value: "abc", selectedRange: CFRange(location: 4, length: 0)), .unreadable)
        XCTAssertEqual(
            HaasFieldState.make(value: "abc", selectedRange: CFRange(location: 2, length: 2)), .unreadable)
        XCTAssertEqual(
            HaasFieldState.make(value: "abc", selectedRange: CFRange(location: -1, length: 0)), .unreadable)
    }

    func testCaretInsideSurrogatePairIsUnreadable() {
        XCTAssertEqual(
            HaasFieldState.make(value: "a💻b", selectedRange: CFRange(location: 2, length: 0)), .unreadable)
    }
}
