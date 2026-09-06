import Foundation
import Combine

public final class DockState: ObservableObject {
    public enum Phase { case idle, starting, listening, transcribing, ready, done, error }
    public enum Mode { case dictation, prompt }

    @Published public var phase: Phase = .idle
    @Published public var level: Float = 0
    @Published public var elapsed: TimeInterval = 0
    @Published public var mode: Mode = .dictation
    @Published public var micName: String = "System default"
    @Published public var serverOK: Bool = false
    /// A meeting is actively being captured (drives the dock's record button and
    /// resting-pill indicator, so you can always tell recording is running).
    @Published public var meetingRecording: Bool = false
    @Published public var meetingElapsed: TimeInterval = 0
    /// The meeting is running but the microphone is not being picked up. Sticky
    /// on purpose: an overlay that fades after eight seconds is exactly how a
    /// whole meeting gets recorded without the user's voice while they sit there
    /// believing it is fine. Cleared when the mic comes back.
    @Published public var meetingMicTrouble: Bool = false
    /// A call was detected and we are offering to record it. Never set without a
    /// real call — a nagging dock is worse than one that stays quiet.
    @Published public var callOffer: Bool = false
    /// The line the offer shows, already humanised ("Teams call"). Built by
    /// CallSource so it can never read like a glitch.
    @Published public var callTitle: String = "Call detected"
    /// PNG bytes of the calling app's icon. Showing the actual app is what makes
    /// the offer feel like it belongs to the call rather than to us.
    @Published public var callIconPNG: Data?
    @Published public var errorText: String = ""
    /// Whether the control bar is revealed (click to expand). Lives here (not as
    /// SwiftUI @State) so toggling it notifies the controller to RESIZE the
    /// floating panel — otherwise the expanded bar clips into the tiny pill's
    /// panel.
    @Published public var expanded: Bool = false

    public init() {}

    public var showsCallOffer: Bool {
        callOffer && !meetingRecording && [.idle, .ready, .done, .error].contains(phase)
    }
    public var canCollapsePresentation: Bool {
        !meetingRecording && !callOffer && [.idle, .ready, .done, .error].contains(phase)
    }
    public func collapsePresentation() { if canCollapsePresentation { expanded = false } }
    public func starting() { expanded = false; phase = .starting; elapsed = 0; errorText = "" }
    public func ready() { phase = .ready; expanded = true }
    public func begin() {
        expanded = false; phase = .listening; elapsed = 0; level = 0; errorText = ""
        meterAt = nil; publishedMeterAt = nil; smoothedLevel = 0
        levels = Array(repeating: 0, count: 24)
    }
    /// The last N levels, oldest first — so the waveform shows speech TRAVELLING
    /// across the dock rather than one fixed shape breathing uniformly. Without
    /// history there is no time in the picture, and the accent bars sat at fixed
    /// indices meaning nothing.
    @Published public var levels: [Float] = Array(repeating: 0, count: 24)

    private var meterAt: TimeInterval?
    private var publishedMeterAt: TimeInterval?
    private var smoothedLevel: Float = 0

    /// Smooth the meter independently of captured PCM. Ten history samples per
    /// second keep the visible time span stable across microphone buffer sizes.
    public func setLevel(_ v: Float, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard phase == .listening else { return }
        let clamped = max(0, min(1, v))
        let dt = max(0, now - (meterAt ?? (now - 0.1)))
        let tau = clamped > smoothedLevel ? 0.08 : 0.28
        smoothedLevel += (clamped - smoothedLevel) * Float(1 - exp(-dt / tau))
        meterAt = now
        guard publishedMeterAt == nil || now - publishedMeterAt! >= 0.099 else { return }
        publishedMeterAt = now
        level = smoothedLevel
        levels.removeFirst()
        levels.append(level)
    }
    public func finishRecording() { if phase == .listening || phase == .starting { phase = .transcribing } }
    /// Words inserted by the last dictation, so the success state can say what
    /// actually happened instead of falling back to an instruction hint.
    @Published public var placementUnverified = false
    @Published public var lastWordCount: Int = 0

    public func complete(words: Int = 0) { placementUnverified = false; lastWordCount = words; phase = .done; expanded = true }
    public func sentUnverified() { placementUnverified = true; phase = .done; expanded = true }
    public func returnToIdle() { phase = .idle; level = 0; expanded = false }
    public func fail(_ msg: String) { phase = .error; errorText = msg; expanded = true }
    public func toggleMode() { mode = (mode == .dictation) ? .prompt : .dictation }
}
