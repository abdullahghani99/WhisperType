import XCTest
@testable import WhisperTypeKit

/// Deciding "a call is happening" from noisy system signals. Every rule here is
/// a judgement call, so every rule is tested — a wrong answer either nags during
/// normal work or stays silent through the meeting you needed captured.
final class CallDetectorTests: XCTestCase {

    private func s(mic: Bool, ours: Bool, app: Bool) -> CallSignals {
        CallSignals(micInUseBySomeone: mic, ourEngineRunning: ours, conferencingAppRunning: app)
    }

    func testNothingHappeningIsNotACall() {
        let d = CallDetector()
        XCTAssertNil(d.update(s(mic: false, ours: false, app: false)))
    }

    /// The trap this detector exists to avoid: our own warm pre-roll engine holds
    /// the microphone permanently, so "a mic is in use" is ALWAYS true while
    /// WhisperType runs. Alone it must never imply a call.
    func testOurOwnWarmEngineIsNotMistakenForACall() {
        let d = CallDetector()
        for _ in 0..<10 {
            XCTAssertNil(d.update(s(mic: true, ours: true, app: false)),
                         "our own pre-roll must not look like a call")
        }
    }

    func testConferencingAppAloneIsNotACall() {
        // Teams sitting open in the background is not a meeting.
        let d = CallDetector()
        for _ in 0..<10 {
            XCTAssertNil(d.update(s(mic: false, ours: false, app: true)))
        }
    }

    func testCallStartsWhenAConferencingAppTakesTheMic() {
        let d = CallDetector()
        var event: CallEvent?
        for _ in 0..<CallDetector.samplesToStart { event = d.update(s(mic: true, ours: true, app: true)) }
        XCTAssertEqual(event, .started)
    }

    func testStartIsDebouncedSoABriefBlipDoesNotNag() {
        let d = CallDetector()
        // One positive sample must not fire — apps touch the mic momentarily.
        XCTAssertNil(d.update(s(mic: true, ours: false, app: true)))
        XCTAssertNil(d.update(s(mic: false, ours: false, app: false)))
        // ...and the counter resets, so the blip cannot accumulate.
        XCTAssertNil(d.update(s(mic: true, ours: false, app: true)))
    }

    func testCallEndsWhenTheMicIsReleased() {
        let d = CallDetector()
        for _ in 0..<CallDetector.samplesToStart { _ = d.update(s(mic: true, ours: false, app: true)) }
        var event: CallEvent?
        for _ in 0..<CallDetector.samplesToEnd { event = d.update(s(mic: false, ours: false, app: true)) }
        XCTAssertEqual(event, .ended, "releasing the mic ends the call — this is what auto-stop hangs on")
    }

    func testEndIsDebouncedAcrossAShortDropout() {
        let d = CallDetector()
        for _ in 0..<CallDetector.samplesToStart { _ = d.update(s(mic: true, ours: false, app: true)) }
        // A single missed sample (device switch mid-call) must NOT end the call.
        XCTAssertNil(d.update(s(mic: false, ours: false, app: true)))
        XCTAssertNil(d.update(s(mic: true, ours: false, app: true)), "call continues")
    }

    func testCallDoesNotStartTwice() {
        let d = CallDetector()
        for _ in 0..<CallDetector.samplesToStart { _ = d.update(s(mic: true, ours: false, app: true)) }
        for _ in 0..<10 {
            XCTAssertNil(d.update(s(mic: true, ours: false, app: true)), "already in a call")
        }
    }

    func testAnotherAppUsingTheMicWithoutAConferencingAppCountsAsACall() {
        // Browser-based Meet, FaceTime, a phone app — we cannot enumerate every
        // conferencing tool, so another process holding the mic while OUR engine
        // is idle is enough.
        let d = CallDetector()
        var event: CallEvent?
        for _ in 0..<CallDetector.samplesToStart { event = d.update(s(mic: true, ours: false, app: false)) }
        XCTAssertEqual(event, .started)
    }
}

/// Remembering where the dock sits on each display.
final class DockPlacementTests: XCTestCase {

    func testUnknownScreenFallsBackToTheDefaultSpot() {
        let p = DockPlacement()
        XCTAssertNil(p.position(forScreen: "screen-A"))
    }

    func testPositionIsRememberedPerScreen() {
        let p = DockPlacement()
        p.remember(x: 100, y: 20, forScreen: "laptop")
        p.remember(x: 900, y: 40, forScreen: "monitor")
        XCTAssertEqual(p.position(forScreen: "laptop")?.x, 100)
        XCTAssertEqual(p.position(forScreen: "monitor")?.x, 900)
        XCTAssertEqual(p.position(forScreen: "monitor")?.y, 40)
    }

    func testRememberingAgainOverwritesThatScreenOnly() {
        let p = DockPlacement()
        p.remember(x: 100, y: 20, forScreen: "laptop")
        p.remember(x: 300, y: 20, forScreen: "laptop")
        p.remember(x: 900, y: 40, forScreen: "monitor")
        XCTAssertEqual(p.position(forScreen: "laptop")?.x, 300)
        XCTAssertEqual(p.position(forScreen: "monitor")?.x, 900, "other screens untouched")
    }
}
