import Foundation
import os

/// Is a capture stream actually delivering AUDIO, as opposed to merely running?
///
/// Every microphone failure in this app has had one shape: the device opens, the
/// tap fires, bytes arrive — and the bytes are zeros. Byte count is not evidence
/// of audio, and a probe at the start cannot see a device that dies later. A
/// ten-minute meeting recorded 17.8MB of microphone data and none of the user's
/// voice, because the only check ran in the first second.
///
/// This watches continuously instead. Feed it every buffer; ask it what the
/// stream is doing. It is deliberately pure — no timers, no clock of its own —
/// so the decisions can be tested without hardware.
public final class MicHealth {
    public enum Verdict: Equatable {
        /// Real audio arrived recently. Nothing to do.
        case live
        /// Too early to judge: a device is allowed a moment to wake up, and
        /// Bluetooth headsets routinely need one to negotiate the mic link.
        case starting
        /// Bytes may still be arriving, but none of them have carried signal.
        case stalled(silentSeconds: Double)
    }

    private let graceSeconds: Double
    private let stallSeconds: Double
    private var startedAt: Double
    private var lastSignalAt: Double?
    private var sawSignal = false
    /// os_unfair_lock rather than NSLock: `observe` runs on the real-time audio
    /// thread, where waiting on a lower-priority thread risks priority inversion
    /// and a dropped buffer — which would itself look like the stall the watchdog
    /// exists to detect. The critical sections here are two stores.
    private var lockPrimitive = os_unfair_lock_s()

    /// - Parameters:
    ///   - graceSeconds: how long a device may take to produce its first audio
    ///     before silence counts against it.
    ///   - stallSeconds: how long a stream that HAS produced audio may go quiet
    ///     before it is treated as stalled. Must comfortably exceed a natural
    ///     pause in speech, or a thoughtful silence looks like a dead mic.
    public init(startedAt: Double, graceSeconds: Double = 3.0, stallSeconds: Double = 12.0) {
        self.startedAt = startedAt
        self.graceSeconds = graceSeconds
        self.stallSeconds = stallSeconds
    }

    /// Call for every buffer. `hasSignal` must be true only when the buffer
    /// contains a non-zero sample: a live mic in a quiet room still carries a
    /// noise floor, so all-zero genuinely means nothing is coming through.
    public func observe(at now: Double, hasSignal: Bool) {
        os_unfair_lock_lock(&lockPrimitive); defer { os_unfair_lock_unlock(&lockPrimitive) }
        if hasSignal {
            lastSignalAt = now
            sawSignal = true
        }
    }

    /// Restart the clock — called after switching to a different device, so the
    /// new one is judged on its own record rather than inheriting the old one's.
    public func reset(at now: Double) {
        os_unfair_lock_lock(&lockPrimitive); defer { os_unfair_lock_unlock(&lockPrimitive) }
        startedAt = now
        lastSignalAt = nil
        sawSignal = false
    }

    /// Has this stream EVER carried audio? A stream that never has is a
    /// different problem from one that stopped, and deserves a different message.
    public var everCarriedAudio: Bool {
        os_unfair_lock_lock(&lockPrimitive); defer { os_unfair_lock_unlock(&lockPrimitive) }
        return sawSignal
    }

    public func verdict(at now: Double) -> Verdict {
        os_unfair_lock_lock(&lockPrimitive); defer { os_unfair_lock_unlock(&lockPrimitive) }
        if let last = lastSignalAt {
            let quiet = now - last
            return quiet >= stallSeconds ? .stalled(silentSeconds: quiet) : .live
        }
        // Never produced a sample yet.
        let waited = now - startedAt
        if waited < graceSeconds { return .starting }
        return .stalled(silentSeconds: waited)
    }
}
