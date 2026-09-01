import XCTest
@testable import WhisperTypeKit

/// One test per fault that previously could only be found by running the app and
/// reading a log. If any of them comes back, this fails instead of a meeting.
final class MicLifecycleTests: XCTestCase {

    // MARK: start / stop re-entrancy

    func testSecondStartIsRefusedWhileTheFirstIsStillComingUp() {
        let l = MicLifecycle()
        XCTAssertEqual(l.requestStart(), .start)
        // The real guard read isRecording, which is only true after two awaits —
        // so a second start ran a competing microphone probe, and the loser
        // nilled the converter under the winner's still-installed tap. The
        // meeting then recorded 0 microphone bytes.
        XCTAssertEqual(l.requestStart(), .busy(.starting))
        l.markRecording()
        XCTAssertEqual(l.requestStart(), .busy(.recording))
    }

    func testStartIsRefusedWhileStopIsStillRunning() {
        let l = MicLifecycle()
        _ = l.requestStart(); l.markRecording()
        XCTAssertTrue(l.requestStop())
        // stop() publishes "not recording" before the stream has shut down. A
        // start admitted here would tear down the new session's objects.
        XCTAssertEqual(l.requestStart(), .busy(.stopping))
        l.finishStop()
        XCTAssertEqual(l.requestStart(), .start)
    }

    func testStopIsRefusedWhenNothingIsRecording() {
        let l = MicLifecycle()
        XCTAssertFalse(l.requestStop())
        _ = l.requestStart()
        XCTAssertFalse(l.requestStop(), "a meeting still coming up has nothing to stop")
    }

    func testAFailedStartReturnsToIdleRatherThanWedgingTheMachine() {
        let l = MicLifecycle()
        XCTAssertEqual(l.requestStart(), .start)
        l.abandonStart()
        XCTAssertEqual(l.requestStart(), .start)
    }

    // MARK: taps from superseded engines

    func testACallbackFromAReplacedEngineIsRejected() {
        let l = MicLifecycle()
        _ = l.requestStart(); l.markRecording()
        let first = l.newTapGeneration()
        XCTAssertTrue(l.isCurrentTap(first))
        let second = l.newTapGeneration()
        // THE bug: an old callback converting through the replacement's converter
        // and recording signal into its health, so a dead device looked alive.
        XCTAssertFalse(l.isCurrentTap(first))
        XCTAssertTrue(l.isCurrentTap(second))
    }

    func testTearingDownSilencesTheTapBeforeStateIsReplaced() {
        let l = MicLifecycle()
        _ = l.requestStart(); l.markRecording()
        let gen = l.newTapGeneration()
        l.invalidateTap()
        XCTAssertFalse(l.isCurrentTap(gen))
    }

    func testStopSilencesTapsSoNothingAppendsAfterTheMeetingEnds() {
        let l = MicLifecycle()
        _ = l.requestStart(); l.markRecording()
        let gen = l.newTapGeneration()
        XCTAssertTrue(l.requestStop())
        XCTAssertFalse(l.isCurrentTap(gen))
    }

    // MARK: bring-up attempts

    func testTwoBringUpsCannotOverlap() {
        let l = MicLifecycle()
        _ = l.requestStart(); l.markRecording()
        let token = l.beginAttempt(at: 0)
        XCTAssertNotNil(token)
        XCTAssertNil(l.beginAttempt(at: 1), "probes sleep; two must never run together")
        l.endAttempt(token!)
        XCTAssertNotNil(l.beginAttempt(at: 2))
    }

    func testAWedgedBringUpIsAbandonedSoLaterAttemptsCanRun() {
        let l = MicLifecycle(wedgeTimeout: 8)
        _ = l.requestStart(); l.markRecording()
        let token = l.beginAttempt(at: 100)!
        XCTAssertFalse(l.abandonIfWedged(at: 105), "5s is not yet wedged")
        // Observed for real: one attempt sat inside AVAudioEngine.start() for 23
        // seconds, and because its slot was never freed the remaining attempts
        // never ran — the microphone stayed dead for the whole meeting.
        XCTAssertTrue(l.abandonIfWedged(at: 110))
        XCTAssertNotNil(l.beginAttempt(at: 111), "the slot must be free again")
        XCTAssertFalse(l.isCurrentAttempt(token), "and the wedged one cannot publish")
    }

    func testAnAbandonedAttemptCannotPublishOverItsReplacement() {
        let l = MicLifecycle(wedgeTimeout: 8)
        _ = l.requestStart(); l.markRecording()
        let stale = l.beginAttempt(at: 0)!
        XCTAssertTrue(l.abandonIfWedged(at: 20))
        let fresh = l.beginAttempt(at: 20)!
        XCTAssertFalse(l.isCurrentAttempt(stale))
        XCTAssertTrue(l.isCurrentAttempt(fresh))
    }

    func testAnAttemptCannotPublishAfterTheMeetingHasStopped() {
        let l = MicLifecycle()
        _ = l.requestStart(); l.markRecording()
        let token = l.beginAttempt(at: 0)!
        XCTAssertTrue(l.isCurrentAttempt(token))
        XCTAssertTrue(l.requestStop())
        // A recovery blocked in engine start would otherwise complete afterwards
        // and leave a microphone running past the end of the recording.
        XCTAssertFalse(l.isCurrentAttempt(token))
    }

    // MARK: recovery budget

    func testRecoveryIsBoundedAndThenReportsExhausted() {
        let l = MicLifecycle(maxRecoveries: 3)
        _ = l.requestStart(); l.markRecording()
        for n in 1...3 {
            guard case .recover(let attempt, let of, let token) = l.requestRecovery(at: Double(n)) else {
                return XCTFail("attempt \(n) should be allowed")
            }
            XCTAssertEqual(attempt, n); XCTAssertEqual(of, 3)
            l.endAttempt(token)          // the caller carries the RESERVED token
        }
        XCTAssertEqual(l.requestRecovery(at: 4), .exhausted)
        // Exhausted stays exhausted — it must not log "giving up" on every tick.
        XCTAssertEqual(l.requestRecovery(at: 5), .exhausted)
    }

    func testTheRecoveryBudgetResetsForEachMeeting() {
        let l = MicLifecycle(maxRecoveries: 3)
        _ = l.requestStart(); l.markRecording()
        for n in 1...3 {
            guard case .recover(_, _, let token) = l.requestRecovery(at: Double(n)) else { return XCTFail() }
            l.endAttempt(token)
        }
        XCTAssertEqual(l.requestRecovery(at: 4), .exhausted)
        _ = l.requestStop(); l.finishStop()
        // Left cumulative, three recoveries in one meeting meant every later
        // meeting gave up without a single attempt.
        XCTAssertEqual(l.requestStart(), .start)
        l.markRecording()
        guard case .recover(let attempt, _, _) = l.requestRecovery(at: 10) else {
            return XCTFail("a new meeting gets a fresh budget")
        }
        XCTAssertEqual(attempt, 1)
    }

    func testASecondRecoveryIsRefusedImmediately() {
        let l = MicLifecycle(maxRecoveries: 3)
        _ = l.requestStart(); l.markRecording()
        guard case .recover = l.requestRecovery(at: 0) else { return XCTFail() }
        // WITHOUT calling beginAttempt: granting recovery must reserve the slot
        // itself. The earlier version of this test called beginAttempt by hand and
        // so passed while the real call order — reserve only after a queued
        // teardown — left a window that burned the whole retry budget in seconds.
        XCTAssertEqual(l.requestRecovery(at: 1), .alreadyRecovering)
        XCTAssertEqual(l.requestRecovery(at: 2), .alreadyRecovering)
    }

    func testARecoveryWedgedBeforeTheMicEvenStartsCanBeAbandoned() {
        let l = MicLifecycle(wedgeTimeout: 8)
        _ = l.requestStart(); l.markRecording()
        guard case .recover(_, _, let token) = l.requestRecovery(at: 0) else { return XCTFail() }
        // The wedge clock starts at the DECISION, so a teardown that blocks before
        // the bring-up is still recoverable.
        XCTAssertTrue(l.abandonIfWedged(at: 20))
        XCTAssertFalse(l.isCurrentAttempt(token))
        guard case .recover = l.requestRecovery(at: 21) else {
            return XCTFail("the slot must be free after abandoning")
        }
    }

    func testRecoveryIsRefusedWhenNoMeetingIsRunning() {
        let l = MicLifecycle()
        XCTAssertEqual(l.requestRecovery(at: 0), .notRecording)
    }

    // MARK: track alignment

    func testOrdinaryCallbackJitterIsNotPadded() {
        // A converted buffer waiting on the lock looks exactly like a gap. Padding
        // it would push the mic track PAST the system track and delay every later
        // word — worse than the drift it was meant to fix.
        XCTAssertEqual(MicLifecycle.padBytes(systemCount: 100_000, micCount: 96_000, minPad: 16_000), 0)
    }

    func testARealOutageIsPaddedToTheSystemClock() {
        XCTAssertEqual(MicLifecycle.padBytes(systemCount: 100_000, micCount: 20_000, minPad: 16_000), 80_000)
    }

    func testAMicAheadOfTheSystemTrackIsNeverPadded() {
        XCTAssertEqual(MicLifecycle.padBytes(systemCount: 50_000, micCount: 60_000, minPad: 16_000), 0)
    }

    func testCoverageExcludesPaddingSoADeadMicCannotReport100() {
        // 30s of system audio, the mic delivered nothing, all of it padded.
        XCTAssertEqual(MicLifecycle.coveragePercent(systemBytes: 960_000, micBytes: 960_000,
                                                   paddedBytes: 960_000), 0)
    }

    func testCoverageReportsDeliveredAudio() {
        XCTAssertEqual(MicLifecycle.coveragePercent(systemBytes: 100_000, micBytes: 100_000,
                                                   paddedBytes: 40_000), 60)
    }

    func testCoverageCannotExceed100() {
        XCTAssertEqual(MicLifecycle.coveragePercent(systemBytes: 100_000, micBytes: 140_000,
                                                   paddedBytes: 0), 100)
    }
}
