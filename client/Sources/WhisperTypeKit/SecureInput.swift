import Foundation

/// What to tell the speaker when macOS secure input blocks insertion.
///
/// Pure, and in the library rather than beside IOKit, so the wording is tested
/// without needing the lock to actually be held.
public enum SecureInput {

    /// `holder` is the app owning the lock, as macOS names it, or nil when the
    /// lookup fails.
    ///
    /// Naming it is the whole point. Secure input is system-wide and only the
    /// owning process can clear it, so "secure input is on" tells the speaker
    /// nothing they can act on. The previous wording guessed at the cause
    /// ("often on the shared screen") and sent them to the wrong machine while
    /// a local terminal held the lock.
    public static func message(holder: String?) -> String {
        let who = holder.map { "\($0) has" } ?? "An app has"
        return "\(who) macOS secure input on, so nothing can type right now — "
             + "usually a password prompt still open in it. Clear or quit it, "
             + "then use Review result."
    }
}
