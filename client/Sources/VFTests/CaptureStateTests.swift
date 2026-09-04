
import WhisperTypeKit

/// The audio capture state machine. Every bug that has reached the user in this
/// area was pure logic — an integer comparison, a threshold, a routing decision —
/// living in an untestable target. These tests exist so that cannot happen again.
final class CaptureStateTests: XCTestCase {

    // MARK: Routing

    func testIdleTapFromCurrentEngineFillsPreroll() {
        let s = CaptureState()
        let epoch = s.commitEngine()
        XCTAssertEqual(s.route(epoch: epoch), .preroll)
    }

    func testRecordingTapFromCurrentEngineIsCaptured() {
        let s = CaptureState()
        let epoch = s.commitEngine()
        s.beginRecording()
        XCTAssertEqual(s.route(epoch: epoch), .recording)
    }

    func testTapFromASupersededEngineIsDiscarded() {
        let s = CaptureState()
        let old = s.commitEngine()
        let new = s.commitEngine()          // engine rebuilt (device change/failure)
        XCTAssertEqual(s.route(epoch: old), .discard)
        XCTAssertEqual(s.route(epoch: new), .preroll)
    }

    /// THE REGRESSION TEST for the bug that shipped: the tap's epoch must survive
    /// a full record/stop cycle. Previously start() and stop() each bumped the
    /// same counter the tap compared against, so after ONE stop the retained tap
    /// matched nothing — it filled neither buffer, and the next "warm" start
    /// returned a header-only WAV while reporting success.
    func testTapStaysValidAcrossRecordStopIdleRecordCycles() {
        let s = CaptureState()
        let epoch = s.commitEngine()

        s.beginRecording()
        XCTAssertEqual(s.route(epoch: epoch), .recording)
        s.endRecording()
        XCTAssertEqual(s.route(epoch: epoch), .preroll, "idle tap must still fill pre-roll")

        s.beginRecording()
        XCTAssertEqual(s.route(epoch: epoch), .recording, "second recording must still capture")
        s.endRecording()
        XCTAssertEqual(s.route(epoch: epoch), .preroll)

        s.beginRecording()
        XCTAssertEqual(s.route(epoch: epoch), .recording, "third recording must still capture")
    }

    func testBeginRecordingTwiceIsRejected() {
        let s = CaptureState()
        _ = s.commitEngine()
        XCTAssertTrue(s.beginRecording())
        XCTAssertFalse(s.beginRecording(), "already recording")
    }

    func testRecordingStopsWhenTheEngineIsInvalidated() {
        let s = CaptureState()
        let epoch = s.commitEngine()
        s.beginRecording()
        s.invalidateEngine()               // device unplugged / teardown
        XCTAssertEqual(s.route(epoch: epoch), .discard)
        XCTAssertFalse(s.isRecording)
    }

    // MARK: Silence classification (tri-state)

    func testAllZeroAudioCondemnsADeviceONLYWhenItLastsLongEnough() {
        // A SHORT all-zero capture is the Bluetooth not-ready window, not a dead
        // device. A real headset delivered 4096 bytes of silence (0.128s) while
        // its mic link came up and was demoted for it, so dictation then avoided
        // the headset the human was wearing.
        XCTAssertEqual(CaptureState.classify(byteCount: 4_096, allZero: true), .inconclusive)
        XCTAssertEqual(CaptureState.classify(byteCount: 12_778, allZero: true), .inconclusive)
        // 0.59s: the PowerConf's DSP wake-up, which the project's hardware notes
        // put at ~500ms. Half a second was not enough headroom.
        XCTAssertEqual(CaptureState.classify(byteCount: 18_890, allZero: true), .inconclusive)
        // Sustained zeros still mean dead hardware — the built-in mic produced
        // 18.1 seconds of them.
        XCTAssertEqual(CaptureState.classify(byteCount: 580_012, allZero: true), .silent)
    }

    func testShortNonZeroCaptureIsInconclusiveNotWorking() {
        // A quick press is not evidence the mic is good OR bad. Marking it
        // "working" previously cleared the penalty on a genuinely broken device.
        XCTAssertEqual(CaptureState.classify(byteCount: 5_000, allZero: false), .inconclusive)
    }

    func testEmptyCaptureIsInconclusiveNotSilent() {
        // Zero bytes means the ENGINE delivered nothing -- which is what happens
        // for a few seconds after the input device changes. Reading it as a dead
        // microphone demoted AirPods, then PowerConf, then the built-in mic
        // inside 40 seconds, leaving nothing to fall back to.
        XCTAssertEqual(CaptureState.classify(byteCount: 0, allZero: true), .inconclusive)
        // A bare WAV header is no more evidence than nothing at all.
        XCTAssertEqual(CaptureState.classify(byteCount: 44, allZero: true), .inconclusive)
    }

    func testLongNonZeroCaptureIsWorking() {
        XCTAssertEqual(CaptureState.classify(byteCount: 200_000, allZero: false), .working)
    }

    // MARK: Pre-roll ring (fixed capacity, no allocation on the audio thread)

    func testRingKeepsOnlyTheMostRecentAudioAndNeverGrows() {
        let ring = PrerollRing(capacityBytes: 8)
        ring.append([1, 2, 3, 4])
        ring.append([5, 6, 7, 8, 9, 10])          // overflows
        let out = ring.drain()
        XCTAssertEqual(out.count, 8, "must cap at capacity")
        XCTAssertEqual(out, [3, 4, 5, 6, 7, 8, 9, 10], "keeps the NEWEST bytes")
    }

    func testDrainEmptiesTheRing() {
        let ring = PrerollRing(capacityBytes: 4)
        ring.append([1, 2, 3])
        XCTAssertEqual(ring.drain(), [1, 2, 3])
        XCTAssertEqual(ring.drain(), [], "drain must reset")
    }

    func testRingHandlesAppendLargerThanCapacity() {
        let ring = PrerollRing(capacityBytes: 4)
        ring.append([1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(ring.drain(), [4, 5, 6, 7])
    }
}
