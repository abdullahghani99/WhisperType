import AppKit

/// Subtle, human audio cues so you don't have to watch the dock: a light "ting"
/// the instant listening starts (you know it heard you), and a soft confirm when
/// your text lands. Quiet by design; mutable via the `vf_muteSounds` default.
enum SoundFeedback {
    static var muted: Bool { UserDefaults.standard.bool(forKey: "vf_muteSounds") }

    /// A light ting the moment recording begins.
    static func listening() { play("Tink", 0.45) }

    /// A soft, lower confirm when the transcript has been inserted.
    static func done() { play("Pop", 0.3) }
    /// A failed dictation MUST NOT sound like a successful one. Without this,
    /// start went "ting" and both outcomes then went silent, so the only way to
    /// learn it had failed was noticing that no text arrived.
    static func failed() { play("Basso", 0.5) }
    /// A call was detected and we are offering to record it. Soft, and distinct
    /// from both the dictation "ting" and the failure tone: an offer you cannot
    /// hear is not an offer. The pill alone was silent, at the bottom centre of
    /// the screen, at the exact moment the human is looking at the person they
    /// just called -- so in real use it was never once noticed.
    static func callOffer() { play("Submarine", 0.35) }

    private static func play(_ name: String, _ volume: Float) {
        guard !muted, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = volume
        sound.play()
    }
}
