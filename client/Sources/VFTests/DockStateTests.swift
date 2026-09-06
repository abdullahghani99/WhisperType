
import WhisperTypeKit

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
        let s = DockState(); s.begin(); s.setLevel(2.0, at: 0); s.setLevel(2.0, at: 2)
        XCTAssertEqual(s.level, 1.0, accuracy: 0.001)
    }
    func testMeterHasStableCadenceAndGentleRelease() {
        let s = DockState(); s.begin()
        s.setLevel(1, at: 0)
        let first = s.level
        s.setLevel(0, at: 0.02)
        XCTAssertEqual(s.level, first)
        s.setLevel(0, at: 0.1)
        XCTAssertTrue(s.level > 0 && s.level < first)
        s.setLevel(0, at: 2)
        XCTAssertTrue(s.level < 0.01)
    }
    func testCallOfferSurfacesOverRecoveryWithoutInterruptingCapture() {
        let s = DockState(); s.ready(); s.callOffer = true
        XCTAssertTrue(s.showsCallOffer)
        s.fail("Audio saved"); XCTAssertTrue(s.showsCallOffer)
        s.callOffer = false; XCTAssertEqual(s.phase, .error)
        XCTAssertEqual(s.errorText, "Audio saved")
        s.callOffer = true; s.begin(); XCTAssertFalse(s.showsCallOffer)
        s.finishRecording(); XCTAssertFalse(s.showsCallOffer)
        s.returnToIdle(); s.meetingRecording = true; XCTAssertFalse(s.showsCallOffer)
    }
    func testCollapseRetainsRecoveryAndProtectsCapture() {
        let s = DockState()
        s.ready(); s.collapsePresentation()
        XCTAssertEqual(s.phase, .ready); XCTAssertFalse(s.expanded)
        s.fail("Audio saved"); s.collapsePresentation()
        XCTAssertEqual(s.phase, .error); XCTAssertEqual(s.errorText, "Audio saved")
        s.begin(); s.expanded = true; s.collapsePresentation()
        XCTAssertTrue(s.expanded); XCTAssertEqual(s.phase, .listening)
        s.finishRecording(); s.collapsePresentation(); XCTAssertTrue(s.expanded)
        s.returnToIdle(); XCTAssertFalse(s.expanded)
        s.meetingRecording = true; s.expanded = true; s.collapsePresentation(); XCTAssertTrue(s.expanded)
    }
}
