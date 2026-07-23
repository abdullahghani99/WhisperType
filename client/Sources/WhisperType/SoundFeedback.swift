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

    private static func play(_ name: String, _ volume: Float) {
        guard !muted, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = volume
        sound.play()
    }
}
