import XCTest
@testable import VoiceInk

@MainActor
final class HaasPTTRecordingTests: XCTestCase {
    func testVisibleIdlePanelStartsOnDownAndFinishesOnlyItsRecordingOnUp() async throws {
        let fixture = HeldRecordingFixture()
        await fixture.handler.handleShortcutDown(action: .primaryRecording, eventTime: 10, mode: .pushToTalk)
        let startedID = try XCTUnwrap(fixture.currentID)
        XCTAssertEqual(fixture.startCount, 1)
        XCTAssertEqual(fixture.toggleCount, 0, "A visible recovery panel must not be toggled away")
        await fixture.handler.handleShortcutUp(action: .primaryRecording, eventTime: 12, mode: .pushToTalk)
        XCTAssertEqual(fixture.finishRequests, [startedID])
        await fixture.handler.handleShortcutUp(action: .primaryRecording, eventTime: 13, mode: .pushToTalk)
        XCTAssertEqual(fixture.finishRequests.count, 1)
        XCTAssertEqual(fixture.toggleCount, 0)
        XCTAssertEqual(fixture.cancelCount, 0)
    }

    func testAStartThatReturnsNoRecordingIDDoesNothingOnRelease() async {
        let fixture = HeldRecordingFixture()
        fixture.start = { nil }
        await fixture.handler.handleShortcutDown(action: .primaryRecording, eventTime: 20, mode: .pushToTalk)
        await fixture.handler.handleShortcutUp(action: .primaryRecording, eventTime: 22, mode: .pushToTalk)
        XCTAssertTrue(fixture.finishRequests.isEmpty)
        XCTAssertEqual(fixture.toggleCount, 0)
    }

    func testLateReleaseForPreviousPressCannotFinishTheNextRecording() async throws {
        let fixture = HeldRecordingFixture()
        await fixture.handler.handleShortcutDown(action: .primaryRecording, eventTime: 30, mode: .pushToTalk)
        let oldID = try XCTUnwrap(fixture.currentID)
        fixture.handler.reset()
        fixture.state = .idle
        fixture.currentID = nil

        await fixture.handler.handleShortcutDown(action: .primaryRecording, eventTime: 32, mode: .pushToTalk)
        let newID = try XCTUnwrap(fixture.currentID)
        XCTAssertNotEqual(oldID, newID)
        await fixture.handler.handleShortcutUp(action: .primaryRecording, eventTime: 31, mode: .pushToTalk)
        XCTAssertTrue(fixture.finishRequests.isEmpty)
        XCTAssertEqual(fixture.currentID, newID)
        await fixture.handler.handleShortcutUp(action: .primaryRecording, eventTime: 34, mode: .pushToTalk)
        XCTAssertEqual(fixture.finishRequests, [newID])
        XCTAssertNil(fixture.currentID)
    }

}

@MainActor
private final class HeldRecordingFixture {
    var state: RecordingState = .idle
    var currentID: UUID?
    var start: (() -> UUID?)?
    var startCount = 0
    var finishRequests: [UUID] = []
    var toggleCount = 0
    var cancelCount = 0

    lazy var handler = RecordingShortcutModeHandler(
        canHandleShortcutAction: { true },
        isRecorderVisible: { true },
        recordingState: { self.state },
        activeRecordingStartID: { self.currentID },
        isShortcutHeld: { _ in false },
        startHeldRecording: {
            self.startCount += 1
            if let start = self.start { return start() }
            let id = UUID()
            self.currentID = id
            self.state = .recording
            return id
        },
        finishHeldRecording: { id in
            self.finishRequests.append(id)
            if id == self.currentID {
                self.state = .idle
                self.currentID = nil
            }
        },
        toggleRecording: { self.toggleCount += 1 },
        cancelRecording: { _ in self.cancelCount += 1 }
    )
}
