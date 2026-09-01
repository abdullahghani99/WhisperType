import Foundation
import os

/// The decisions behind capturing a microphone, with no microphone attached.
///
/// Every fault in the meeting recorder was a decision fault, not an audio fault:
/// a second start slipping through a guard that was set after an `await`; a
/// callback from a replaced engine writing into its replacement's state; a
/// recovery wedged in `AVAudioEngine.start()` blocking every later attempt; a
/// retry budget that was never reset; padding that could push one track past the
/// other. Each was found by running the app, because the logic could not be
/// reached any other way.
///
/// Pulling it out here makes those decisions testable, so the same faults cannot
/// come back quietly. It holds no AVAudioEngine, no CoreAudio, and no clock —
/// callers pass the time in.
public final class MicLifecycle {

    /// One phase at a time. Booleans let contradictory states coexist: the
    /// recorder previously had `starting`, `stopping`, `isRecording`,
    /// `micStarting`, `recovering` and `gaveUpOnMic` all independently settable.
    public enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping
    }

    public enum StartDecision: Equatable {
        case start
        /// Refused. The caller must NOT report that recording began — doing so
        /// showed a red indicator while nothing was being captured.
        case busy(Phase)
    }

    private var phase: Phase = .idle
    /// Identifies the engine a tap belongs to. A callback carrying a stale
    /// generation must do nothing at all.
    private var tapGeneration = 0
    /// Identifies one attempt to bring a microphone up. An abandoned attempt can
    /// still return minutes later; it must not publish over a newer one.
    private var attemptToken = 0
    private var attemptInFlight = false
    private var attemptStartedAt: Double = 0
    private var recoveries = 0
    private var gaveUp = false
    private var lockPrimitive = os_unfair_lock_s()

    public let maxRecoveries: Int
    /// A bring-up taking longer than this is presumed wedged. Measured: one sat
    /// inside AVAudioEngine.start() for 23 seconds on a Bluetooth transition.
    public let wedgeTimeout: Double

    public init(maxRecoveries: Int = 3, wedgeTimeout: Double = 8.0) {
        self.maxRecoveries = maxRecoveries
        self.wedgeTimeout = wedgeTimeout
    }

    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lockPrimitive); defer { os_unfair_lock_unlock(&lockPrimitive) }
        return body()
    }

    public var currentPhase: Phase { locked { phase } }

    // MARK: meeting lifecycle

    /// Claim the right to start, synchronously. The old guard read `isRecording`,
    /// which is only true after two awaits, so a second start walked straight
    /// into the gap and ran a competing microphone probe.
    public func requestStart() -> StartDecision {
        locked {
            guard phase == .idle else { return .busy(phase) }
            phase = .starting
            recoveries = 0          // per MEETING: left cumulative, a later
            gaveUp = false          // meeting gave up without ever trying
            return .start
        }
    }

    public func markRecording() {
        locked { if phase == .starting { phase = .recording } }
    }

    /// A start that failed before capture began returns the machine to idle.
    public func abandonStart() {
        locked { if phase == .starting { phase = .idle } }
    }

    /// Claim the right to stop. Returns false when there is nothing to stop, or a
    /// stop is already running.
    public func requestStop() -> Bool {
        locked {
            guard phase == .recording else { return false }
            phase = .stopping
            // Invalidate BOTH: silencing taps is not enough, because an attempt
            // wedged in engine start would still publish its engine afterwards
            // and leave a microphone live past the end of the meeting.
            tapGeneration &+= 1
            attemptToken &+= 1
            attemptInFlight = false
            return true
        }
    }

    public func finishStop() {
        locked { phase = .idle }
    }

    public var isCapturing: Bool { locked { phase == .recording } }

    // MARK: engine generations

    public func newTapGeneration() -> Int {
        locked { tapGeneration &+= 1; return tapGeneration }
    }

    /// Called from the real-time audio thread for every buffer.
    public func isCurrentTap(_ generation: Int) -> Bool {
        locked { generation == tapGeneration }
    }

    /// Invalidate the current tap without other side effects — used when tearing
    /// an engine down, so an in-flight callback becomes a no-op before it can
    /// touch state belonging to its replacement.
    public func invalidateTap() {
        locked { tapGeneration &+= 1 }
    }

    // MARK: bring-up attempts

    /// Begin an attempt to open a microphone. Returns nil when one is already
    /// running, so two probes can never overlap.
    public func beginAttempt(at now: Double) -> Int? {
        locked {
            guard !attemptInFlight else { return nil }
            attemptInFlight = true
            attemptStartedAt = now
            attemptToken &+= 1
            return attemptToken
        }
    }

    public func endAttempt(_ token: Int) {
        locked { if token == attemptToken { attemptInFlight = false } }
    }

    /// Is this attempt still the current one? Must be asked BEFORE touching any
    /// shared state, not only before publishing: an abandoned attempt used to
    /// overwrite the shared converter and probe counter on its way to the check.
    public func isCurrentAttempt(_ token: Int) -> Bool {
        locked { token == attemptToken && (phase == .starting || phase == .recording) }
    }

    /// Has the in-flight attempt hung? Abandoning it frees the slot and moves the
    /// token, so the next attempt can run and the wedged one cannot publish.
    public func abandonIfWedged(at now: Double) -> Bool {
        locked {
            guard attemptInFlight, now - attemptStartedAt > wedgeTimeout else { return false }
            attemptInFlight = false
            attemptToken &+= 1
            return true
        }
    }

    // MARK: recovery budget

    public enum RecoveryDecision: Equatable {
        /// The attempt is RESERVED by this call — slot taken and wedge clock
        /// started — and its token must be carried into the bring-up. Granting
        /// recovery without reserving left a window in which later ticks saw no
        /// attempt in flight, spent the remaining budget, and could not abandon
        /// the blocked queue either.
        case recover(attempt: Int, of: Int, token: Int)
        /// Out of attempts. Retrying stops; the caller must keep its clock-keeping
        /// running, because stopping that let the two tracks drift apart.
        case exhausted
        case alreadyRecovering
        case notRecording
    }

    public func requestRecovery(at now: Double) -> RecoveryDecision {
        locked {
            guard phase == .recording else { return .notRecording }
            if gaveUp { return .exhausted }
            guard !attemptInFlight else { return .alreadyRecovering }
            guard recoveries < maxRecoveries else { gaveUp = true; return .exhausted }
            recoveries += 1
            attemptInFlight = true          // reserve and timestamp ATOMICALLY
            attemptStartedAt = now
            attemptToken &+= 1
            return .recover(attempt: recoveries, of: maxRecoveries, token: attemptToken)
        }
    }

    public var hasGivenUp: Bool { locked { gaveUp } }

    // MARK: track alignment

    /// How much silence to insert so the microphone track stays on the system
    /// clock. `mix()` aligns by index, so an outage would otherwise slide every
    /// later word earlier, over the wrong system audio.
    ///
    /// Returns 0 for small differences on purpose: a converted buffer waiting on
    /// a lock looks exactly like a gap, and padding that would push the mic track
    /// PAST the system track, delaying all later speech instead of aligning it.
    public static func padBytes(systemCount: Int, micCount: Int, minPad: Int) -> Int {
        let gap = systemCount - micCount
        return gap >= minPad ? gap : 0
    }

    /// Coverage as a percentage of the system track, counting only DELIVERED
    /// audio. Padding must be excluded or a dead microphone reports 100%.
    public static func coveragePercent(systemBytes: Int, micBytes: Int, paddedBytes: Int) -> Int {
        guard systemBytes > 0 else { return 0 }
        let delivered = max(0, micBytes - paddedBytes)
        return min(100, Int(Double(delivered) / Double(systemBytes) * 100))
    }
}
