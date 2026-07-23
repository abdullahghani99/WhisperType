import XCTest
@testable import WhisperTypeKit

/// Smoke tests over the DockState machine — covering the transitions whose bugs
/// reached the user this session (stuck error, expand not resizing, stuck phases).
final class SmokeTests: XCTestCase {
    func testExpandedDefaultsFalse() {
        XCTAssertFalse(DockState().expanded)
    }

    func testCompleteThenReturnToIdle() {
        let s = DockState(); s.begin(); s.finishRecording(); s.complete()
        XCTAssertEqual(s.phase, .done)
        s.returnToIdle()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(s.level, 0)
    }

    func testFailIsRecoverable() {
        // The "stuck at No audio" bug: fail() must be exitable back to idle.
        let s = DockState(); s.fail("No audio")
        XCTAssertEqual(s.phase, .error)
        s.returnToIdle()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(s.errorText, "No audio")   // text persists until next begin
    }

    func testBeginClearsPriorError() {
        let s = DockState(); s.fail("boom"); s.begin()
        XCTAssertEqual(s.phase, .listening)
        XCTAssertEqual(s.errorText, "")
    }

    func testLevelIgnoredOutsideListening() {
        let s = DockState()
        s.setLevel(0.8)
        XCTAssertEqual(s.level, 0)          // idle → ignored
        s.begin(); s.setLevel(0.8)
        XCTAssertEqual(s.level, 0.8, accuracy: 0.001)
        s.finishRecording(); s.setLevel(0.2)
        XCTAssertEqual(s.level, 0.8, accuracy: 0.001)   // transcribing → ignored
    }
}
