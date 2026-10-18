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
        // macOS's own login process keeps the lock after a lock/unlock -- held
        // 10+ hours on 2026-10-17. Quitting it logs the speaker out.
        if holder?.lowercased() == "loginwindow" {
            return "macOS loginwindow has secure input on, and WhisperType could not verify an ordinary destination text field. "
                 + "Try locking the screen (Ctrl+Cmd+Q) and unlocking, then use Review result. "
                 + "Your dictation is saved. You can also use Copy result in the recording’s options menu and paste it yourself."
        }
        let who = holder.map { "\($0) has" } ?? "An app has"
        return "\(who) macOS secure input on, and WhisperType could not verify an ordinary destination text field. "
             + "Finish any password entry in that app, then use Review result. "
             + "Your dictation is saved. You can also use Copy result in the recording’s options menu and paste it yourself."
    }
}
