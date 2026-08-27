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

    public func begin() { phase = .listening; elapsed = 0; level = 0; errorText = "" }
    public func setLevel(_ v: Float) { if phase == .listening { level = max(0, min(1, v)) } }
    public func finishRecording() { if phase == .listening { phase = .transcribing } }
    public func complete() { phase = .done }
    public func returnToIdle() { phase = .idle; level = 0 }
    public func fail(_ msg: String) { phase = .error; errorText = msg }
    public func toggleMode() { mode = (mode == .dictation) ? .prompt : .dictation }
}
