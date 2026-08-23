import Foundation

/// Where an incoming audio buffer belongs.
public enum AudioRoute: Equatable {
    /// Append to the active recording.
    case recording
    /// Keep in the pre-roll ring, so the next press starts with audio in hand.
    case preroll
    /// Came from an engine we have replaced — throw it away.
    case discard
}

/// What a finished capture tells us about the microphone.
public enum CaptureVerdict: Equatable {
    /// Real audio arrived — the device works.
    case working
    /// The device produced nothing usable.
    case silent
    /// Too short to judge. A quick press is evidence of nothing, and treating it
    /// as either success or failure has caused real bugs: marking a broken device
    /// "working" pinned it, and marking a good device "silent" sent the next
    /// press to a different cold mic, turning one miss into three.
    case inconclusive
}

/// The audio capture state machine, deliberately free of AVFoundation so it can
/// be unit-tested.
///
/// The central distinction — and the source of a bug that shipped — is between:
///
///   * the ENGINE EPOCH, which changes only when the audio engine is actually
///     rebuilt (device change, failure, teardown), and
///   * whether we are currently RECORDING, which changes on every press.
///
/// A tap is installed once per engine and lives across many recordings, so it
/// must validate against the engine epoch. Validating it against a per-press
/// counter meant that after a single stop the retained tap matched nothing: it
/// filled neither buffer, and the next recording returned an empty WAV while
/// reporting success.
public final class CaptureState {
    private let lock = NSLock()
    private var epoch = 0
    private var live = false
    private var _isRecording = false

    public init() {}

    public var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRecording
    }

    public var currentEpoch: Int {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }

    /// A new engine is now the committed one. Returns the epoch its tap must
    /// carry; buffers stamped with any earlier epoch are discarded.
    @discardableResult
    public func commitEngine() -> Int {
        lock.lock(); defer { lock.unlock() }
        epoch += 1
        live = true
        _isRecording = false
        return epoch
    }

    /// The committed engine is gone (device changed, torn down, failed). Any
    /// recording in progress ends — there is nothing feeding it.
    public func invalidateEngine() {
        lock.lock(); defer { lock.unlock() }
        live = false
        _isRecording = false
    }

    /// True if recording actually began.
    @discardableResult
    public func beginRecording() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard live, !_isRecording else { return false }
        _isRecording = true
        return true
    }

    public func endRecording() {
        lock.lock(); defer { lock.unlock() }
        _isRecording = false
    }

    /// Where a buffer from the tap stamped with `epoch` belongs.
    public func route(epoch tapEpoch: Int) -> AudioRoute {
        lock.lock(); defer { lock.unlock() }
        guard live, tapEpoch == epoch else { return .discard }
        return _isRecording ? .recording : .preroll
    }

    /// Enough audio that silence is meaningful: ~0.75 s at 16 kHz mono int16.
    static let evidenceBytes = 24_000

    /// Judge a finished capture. All-zero PCM means a dead device at ANY length —
    /// a working microphone in a silent room still carries a noise floor.
    public static func classify(byteCount: Int, allZero: Bool) -> CaptureVerdict {
        if allZero { return .silent }
        if byteCount >= evidenceBytes { return .working }
        return .inconclusive
    }
}

/// Fixed-capacity pre-roll buffer.
///
/// Preallocated and index-based on purpose: it is written from the real-time
/// audio thread, where allocating or compacting a growing buffer risks dropped
/// callbacks. Appending never allocates and never moves more than the incoming
/// bytes.
public final class PrerollRing {
    private var storage: [UInt8]
    private var writeIndex = 0
    private var filled = 0
    private let lock = NSLock()

    public init(capacityBytes: Int) {
        storage = [UInt8](repeating: 0, count: max(1, capacityBytes))
    }

    public func append(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        let cap = storage.count
        // Only the last `cap` bytes can survive, so skip anything older.
        let start = bytes.count > cap ? bytes.count - cap : 0
        for i in start..<bytes.count {
            storage[writeIndex] = bytes[i]
            writeIndex = (writeIndex + 1) % cap
            if filled < cap { filled += 1 }
        }
    }

    /// The buffered audio, oldest first, and reset.
    public func drain() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        guard filled > 0 else { return [] }
        let cap = storage.count
        var out = [UInt8](); out.reserveCapacity(filled)
        let startIdx = (writeIndex - filled + cap) % cap
        for i in 0..<filled { out.append(storage[(startIdx + i) % cap]) }
        writeIndex = 0; filled = 0
        return out
    }

    public func reset() {
        lock.lock(); writeIndex = 0; filled = 0; lock.unlock()
    }
}
