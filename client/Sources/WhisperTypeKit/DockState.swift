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
