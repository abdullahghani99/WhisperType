import Foundation
import Combine

public final class DockState: ObservableObject {
    public enum Phase { case idle, listening, transcribing, done, error }
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

    public func begin() {
        phase = .listening; elapsed = 0; level = 0; errorText = ""
        levels = Array(repeating: 0, count: 24)
    }
    /// The last N levels, oldest first — so the waveform shows speech TRAVELLING
    /// across the dock rather than one fixed shape breathing uniformly. Without
    /// history there is no time in the picture, and the accent bars sat at fixed
    /// indices meaning nothing.
    @Published public var levels: [Float] = Array(repeating: 0, count: 24)

    public func setLevel(_ v: Float) {
        guard phase == .listening else { return }
        let clamped = max(0, min(1, v))
        level = clamped
        levels.removeFirst()
        levels.append(clamped)
    }
    public func finishRecording() { if phase == .listening { phase = .transcribing } }
    /// Words inserted by the last dictation, so the success state can say what
    /// actually happened instead of falling back to an instruction hint.
    @Published public var lastWordCount: Int = 0

    public func complete(words: Int = 0) { lastWordCount = words; phase = .done }
    public func returnToIdle() { phase = .idle; level = 0 }
    public func fail(_ msg: String) { phase = .error; errorText = msg }
    public func toggleMode() { mode = (mode == .dictation) ? .prompt : .dictation }
}
