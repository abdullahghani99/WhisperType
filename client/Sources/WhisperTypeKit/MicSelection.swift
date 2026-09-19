import Foundation

/// Which microphones WhisperType will record from.
///
/// Pure, and in the library rather than beside CoreAudio, so it can be tested
/// without hardware — the app target is not linked by the test runner.
public enum MicSelection {

    /// Whether a device may be used for recording at all.
    ///
    /// Continuity microphones (iPhone, iPad) are refused by default for the same
    /// reason virtual devices are: macOS keeps flipping the system default onto
    /// them, and a capture that lands on a phone in another room records nothing
    /// useful. Opening a virtual device is worse still — it wedges the audio HAL
    /// so the NEXT capture returns zero bytes from everything.
    ///
    /// But refusing them ABSOLUTELY left no fallback at all on 2026-09-15, when
    /// CoreAudio wedged the built-in microphone: it kept clocking and delivered
    /// pure silence for four minutes, while the speaker's iPhone microphone
    /// worked throughout and this filter would not touch it.
    ///
    /// So the ban holds for automatic selection and yields to an explicit one: a
    /// device the speaker pinned themselves is always allowed. They can see what
    /// they picked; the automatic path cannot.
    public static func allows(uid: String, name: String, physical: Bool,
                              bluetooth: Bool, pinned: String, allowBluetooth: Bool) -> Bool {
        if !pinned.isEmpty && uid == pinned { return true }   // the speaker's own choice
        if !physical { return false }
        let lower = name.lowercased()
        if lower.contains("iphone") || lower.contains("ipad") { return false }
        return allowBluetooth || !bluetooth
    }
}
