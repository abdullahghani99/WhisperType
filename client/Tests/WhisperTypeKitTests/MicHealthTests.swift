import XCTest
@testable import WhisperTypeKit

/// These encode the failure that lost a real ten-minute meeting: a microphone
/// that passed its opening probe, then stopped carrying audio, with bytes still
/// arriving the whole time.
final class MicHealthTests: XCTestCase {

    func testDeviceIsGivenTimeToWakeUpBeforeBeingJudged() {
        let h = MicHealth(startedAt: 0, graceSeconds: 3, stallSeconds: 12)
        // Bluetooth headsets need a moment to negotiate the mic link. Condemning
        // them instantly is how a working headset got demoted.
        XCTAssertEqual(h.verdict(at: 0.5), .starting)
        XCTAssertEqual(h.verdict(at: 2.9), .starting)
    }

    func testDeviceThatNeverDeliversIsStalledOnceGraceExpires() {
        let h = MicHealth(startedAt: 0, graceSeconds: 3, stallSeconds: 12)
        XCTAssertEqual(h.verdict(at: 3.1), .stalled(silentSeconds: 3.1))
        XCTAssertFalse(h.everCarriedAudio)
    }

    func testSignalMakesItLive() {
        let h = MicHealth(startedAt: 0, graceSeconds: 3, stallSeconds: 12)
        h.observe(at: 1.0, hasSignal: true)
        XCTAssertEqual(h.verdict(at: 1.1), .live)
        XCTAssertTrue(h.everCarriedAudio)
    }

    func testZeroFilledBuffersDoNotCountAsSignal() {
        let h = MicHealth(startedAt: 0, graceSeconds: 3, stallSeconds: 12)
        // THE bug: bytes arriving while carrying nothing. 17.8MB of these was
        // read as a working microphone for a whole meeting.
        for t in stride(from: 0.0, through: 10.0, by: 0.1) {
            h.observe(at: t, hasSignal: false)
        }
        XCTAssertEqual(h.verdict(at: 10.0), .stalled(silentSeconds: 10.0))
        XCTAssertFalse(h.everCarriedAudio)
    }

    func testMicThatDiesMidStreamIsCaught() {
        let h = MicHealth(startedAt: 0, graceSeconds: 3, stallSeconds: 12)
        // Passes its opening probe...
        for t in stride(from: 0.0, through: 20.0, by: 0.1) {
            h.observe(at: t, hasSignal: true)
        }
        XCTAssertEqual(h.verdict(at: 20.0), .live)
        // ...then stops carrying audio for the rest of the meeting.
        for t in stride(from: 20.1, through: 40.0, by: 0.1) {
            h.observe(at: t, hasSignal: false)
        }
        guard case .stalled(let quiet) = h.verdict(at: 40.0) else {
            return XCTFail("a mic that died mid-meeting must be reported stalled")
        }
        XCTAssertEqual(quiet, 20.0, accuracy: 0.01)
        // It DID work once, so the message should say it stopped, not that it
        // never started.
        XCTAssertTrue(h.everCarriedAudio)
    }

    func testAPauseInSpeechIsNotAStall() {
        let h = MicHealth(startedAt: 0, graceSeconds: 3, stallSeconds: 12)
        h.observe(at: 1.0, hasSignal: true)
        // Thinking for eight seconds mid-sentence must not look like a dead mic.
        XCTAssertEqual(h.verdict(at: 9.0), .live)
    }

    func testResetJudgesANewDeviceOnItsOwnRecord() {
        let h = MicHealth(startedAt: 0, graceSeconds: 3, stallSeconds: 12)
        for t in stride(from: 0.0, through: 20.0, by: 0.5) { h.observe(at: t, hasSignal: false) }
        XCTAssertEqual(h.verdict(at: 20.0), .stalled(silentSeconds: 20.0))
        // Switched to another microphone: it starts clean, not already condemned.
        h.reset(at: 20.0)
        XCTAssertEqual(h.verdict(at: 21.0), .starting)
        XCTAssertFalse(h.everCarriedAudio)
    }
}
