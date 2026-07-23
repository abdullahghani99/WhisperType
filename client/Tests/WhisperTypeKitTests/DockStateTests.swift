import XCTest
@testable import WhisperTypeKit

final class DockStateTests: XCTestCase {
    func testBeginEntersListening() {
        let s = DockState()
        s.begin()
        XCTAssertEqual(s.phase, .listening)
        XCTAssertEqual(s.elapsed, 0)
    }
    func testFinishThenCompleteReturnsToIdle() {
        let s = DockState(); s.begin(); s.finishRecording()
        XCTAssertEqual(s.phase, .transcribing)
        s.complete()
        XCTAssertEqual(s.phase, .done)
    }
    func testFailEntersErrorWithText() {
        let s = DockState(); s.begin(); s.fail("Mic unavailable")
        XCTAssertEqual(s.phase, .error)
        XCTAssertEqual(s.errorText, "Mic unavailable")
    }
    func testToggleModeFlips() {
        let s = DockState()
        XCTAssertEqual(s.mode, .dictation)
        s.toggleMode()
        XCTAssertEqual(s.mode, .prompt)
    }
    func testSetLevelClampsAndStoresWhileListening() {
        let s = DockState(); s.begin(); s.setLevel(2.0)
        XCTAssertEqual(s.level, 1.0, accuracy: 0.001)
    }
}
