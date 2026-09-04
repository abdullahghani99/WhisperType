import Foundation

/// A snapshot of what the system looks like right now.
public struct CallSignals: Equatable {
    /// Any input device is running somewhere — i.e. SOME process is capturing.
    public let micInUseBySomeone: Bool
    /// Our own pre-roll/dictation engine is one of those processes.
    public let ourEngineRunning: Bool
    /// A real conferencing app is running (Teams, Zoom, Webex, FaceTime).
    /// Browsers are deliberately excluded: they are always running, so including
    /// them made "a call" indistinguishable from an ordinary Tuesday.
    public let conferencingAppRunning: Bool
    /// Audio is coming OUT of a device. This is the signal we do not pollute:
    /// VoiceFlow captures but never plays, so unlike the microphone this stays
    /// honest while our warm engine is running.
    public let audioPlayingSomewhere: Bool

    public init(micInUseBySomeone: Bool, ourEngineRunning: Bool,
                conferencingAppRunning: Bool, audioPlayingSomewhere: Bool = false) {
        self.micInUseBySomeone = micInUseBySomeone
        self.ourEngineRunning = ourEngineRunning
        self.conferencingAppRunning = conferencingAppRunning
        self.audioPlayingSomewhere = audioPlayingSomewhere
    }
}

public enum CallEvent: Equatable { case started, ended }

/// Decides when a call begins and ends, from signals that are individually
/// ambiguous.
///
/// The hard part is our own microphone. Keeping the engine warm is what makes
/// dictation reliable, but it means "a mic is in use" is true for as long as
/// VoiceFlow runs — so that signal alone can never mean "a call". A call is
/// therefore either another process holding the mic while we are idle, or the
/// mic held while a conferencing app is up.
///
/// Both edges are debounced. Apps touch the microphone briefly for all sorts of
/// reasons, and a device switch mid-call drops the signal for a moment; without
/// debouncing the first would nag during ordinary work and the second would stop
/// a recording in the middle of the meeting.
public final class CallDetector {
    /// ~1.5s at a 0.5s poll: long enough to ignore a blip, short enough to offer
    /// before the conversation has really started.
    public static let samplesToStart = 3
    /// ~2.5s: a call is not over just because a device changed.
    public static let samplesToEnd = 5

    private var positives = 0
    private var negatives = 0
    private var inCall = false
    private let lock = NSLock()

    public init() {}

    public var isInCall: Bool { lock.lock(); defer { lock.unlock() }; return inCall }

    /// Feed one poll. Returns an event only on a transition.
    @discardableResult
    public func update(_ s: CallSignals) -> CallEvent? {
        lock.lock(); defer { lock.unlock() }

        // The microphone cannot be the primary signal any more: our own warm
        // pre-roll engine holds it for as long as VoiceFlow runs, so "a mic is in
        // use" is true every second of the day. Relying on it made the app
        // "detect a call" at launch, latch, and then stay silent through the real
        // one.
        //
        // A call is a conferencing app that is BOTH capturing and playing. Audio
        // output is the honest half — VoiceFlow records but never plays, so it
        // never contaminates that signal.
        let somebodyElseHasTheMic = s.micInUseBySomeone && !s.ourEngineRunning
        let conferenceIsLive = s.conferencingAppRunning && s.audioPlayingSomewhere
        let looksLikeACall = conferenceIsLive || somebodyElseHasTheMic

        if looksLikeACall {
            negatives = 0
            guard !inCall else { return nil }
            positives += 1
            if positives >= Self.samplesToStart {
                inCall = true; positives = 0
                return .started
            }
        } else {
            positives = 0
            guard inCall else { return nil }
            negatives += 1
            if negatives >= Self.samplesToEnd {
                inCall = false; negatives = 0
                return .ended
            }
        }
        return nil
    }

    public func reset() {
        lock.lock(); positives = 0; negatives = 0; inCall = false; lock.unlock()
    }
}

/// Where the dock sits on each display.
///
/// One remembered position is wrong on a multi-display desk: the dock ends up on
/// whichever screen happened to be main at launch, which is why it kept appearing
/// off to one side. Position is therefore stored per screen and restored when you
/// move between them.
public final class DockPlacement {
    public struct Point: Equatable { public let x: Double; public let y: Double }

    private var byScreen: [String: Point] = [:]
    private let lock = NSLock()
    private let defaultsKey = "vf_dockPositions"
    private let store: UserDefaults?

    public init(store: UserDefaults? = nil) {
        self.store = store
        if let raw = store?.dictionary(forKey: defaultsKey) as? [String: [String: Double]] {
            for (k, v) in raw {
                if let x = v["x"], let y = v["y"] { byScreen[k] = Point(x: x, y: y) }
            }
        }
    }

    public func position(forScreen id: String) -> Point? {
        lock.lock(); defer { lock.unlock() }
        return byScreen[id]
    }

    public func remember(x: Double, y: Double, forScreen id: String) {
        lock.lock()
        byScreen[id] = Point(x: x, y: y)
        let snapshot = byScreen
        lock.unlock()
        store?.set(snapshot.mapValues { ["x": $0.x, "y": $0.y] }, forKey: defaultsKey)
    }
}
