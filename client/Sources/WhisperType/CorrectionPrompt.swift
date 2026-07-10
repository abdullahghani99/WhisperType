import Cocoa

/// A small modal editor for teaching a correction: shows the dictation text in
/// an editable field so the user fixes it, then returns the edited string (or
/// nil if cancelled). Must be called on the main thread.
enum CorrectionPrompt {
    static func run(prefill: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Correct this dictation"
        alert.informativeText = "Fix any wrong words below. WhisperType learns the difference and suggests vocabulary fixes."
        alert.addButton(withTitle: "Teach fix")
        alert.addButton(withTitle: "Cancel")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.autoresizingMask = [.width, .height]
        text.isEditable = true
        text.isRichText = false
        text.font = .systemFont(ofSize: 13)
        text.string = prefill
        scroll.documentView = text
        alert.accessoryView = scroll

        // Focus the editor with the caret at the end.
        alert.window.initialFirstResponder = text
        text.setSelectedRange(NSRange(location: prefill.count, length: 0))

        return alert.runModal() == .alertFirstButtonReturn
            ? text.string.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }
}
