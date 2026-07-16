import Cocoa

/// Interactive review panel for prompt mode. Shows the engineered prompt and
/// lets the user flip Concise/Detailed/Coding, EDIT it inline, then insert (⌘⏎)
/// or cancel (esc). Non-destructive: nothing is typed until the user inserts.
///
/// Because the text is editable, level switching and insert use ⌘ so plain
/// typing (incl. digits and newlines) edits the text:
///   ⌘1 Concise · ⌘2 Detailed · ⌘3 Coding · ⌘⏎ Insert · esc Cancel
///
/// The panel becomes key to capture these; the caller restores focus to the
/// target app before typing the chosen text.
final class PromptReviewController {
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var levelLabel: NSTextField?
    private var keyMonitor: Any?

    private let names = ["Concise", "Detailed", "Coding"]
    private var levels = ["", "", ""]   // editable text per level (edits persist)
    private var index = 0
    private var onChoose: ((String?) -> Void)?   // chosen text to insert, or nil = cancel

    private static let ink = NSColor(calibratedRed: 0x1A/255, green: 0x17/255, blue: 0x14/255, alpha: 0.98)
    private static let accent = NSColor(calibratedRed: 0xE7/255, green: 0x00/255, blue: 0x0B/255, alpha: 1)

    /// Show the panel. `onChoose` is called exactly once with the chosen
    /// (possibly edited) text, or nil if the user cancelled.
    func show(concise: String, detailed: String, coding: String,
              onChoose: @escaping (String?) -> Void) {
        self.levels = [concise, detailed, coding]
        self.index = 0
        self.onChoose = onChoose
        buildPanel()
        render()
        NSApp.activate(ignoringOtherApps: true)
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(textView)
        installMonitor()
    }

    private func buildPanel() {
        if panel != nil { return }
        let w: CGFloat = 660, h: CGFloat = 460
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "Prompt — review & edit"
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.backgroundColor = Self.ink

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let header = NSTextField(labelWithString: "Engineered prompt — edit if you like")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .white
        header.frame = NSRect(x: 20, y: h - 52, width: 360, height: 20)
        content.addSubview(header)

        let level = NSTextField(labelWithString: "")
        level.font = .systemFont(ofSize: 12, weight: .medium)
        level.alignment = .right
        level.frame = NSRect(x: w - 340, y: h - 52, width: 320, height: 20)
        content.addSubview(level)
        levelLabel = level

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 48, width: w - 32, height: h - 108))
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = true
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.drawsBackground = false
        tv.textColor = NSColor(white: 0.95, alpha: 1)
        tv.insertionPointColor = Self.accent
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        content.addSubview(scroll)
        textView = tv

        let footer = NSTextField(labelWithString:
            "⌘1 Concise      ⌘2 Detailed      ⌘3 Coding      ⌘⏎ Insert      esc Cancel")
        footer.font = .systemFont(ofSize: 12, weight: .regular)
        footer.textColor = NSColor(white: 0.65, alpha: 1)
        footer.alignment = .center
        footer.frame = NSRect(x: 16, y: 16, width: w - 32, height: 18)
        footer.autoresizingMask = [.width, .minYMargin]
        content.addSubview(footer)

        p.contentView = content
        panel = p
    }

    /// Load the current level's text into the view and update the level pills.
    private func render() {
        textView?.string = levels[index]
        textView?.scrollToBeginningOfDocument(nil)
        let attr = NSMutableAttributedString()
        for (i, name) in names.enumerated() {
            if i > 0 { attr.append(NSAttributedString(string: "   ", attributes: nil)) }
            let active = i == index
            attr.append(NSAttributedString(string: name, attributes: [
                .foregroundColor: active ? Self.accent : NSColor(white: 0.5, alpha: 1),
                .font: NSFont.systemFont(ofSize: 12, weight: active ? .semibold : .regular),
            ]))
        }
        levelLabel?.attributedStringValue = attr
    }

    /// Persist any edits made to the currently shown level.
    private func saveCurrentEdits() {
        if let s = textView?.string { levels[index] = s }
    }

    private func switchTo(_ i: Int) {
        guard i != index, i >= 0, i < levels.count else { return }
        saveCurrentEdits()
        index = i
        render()
    }

    private func installMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {                       // esc → cancel
            dismiss(nil); return nil
        }
        guard event.modifierFlags.contains(.command) else { return event }  // else: normal typing
        if event.keyCode == 36 || event.keyCode == 76 {  // ⌘⏎ → insert
            saveCurrentEdits(); dismiss(levels[index]); return nil
        }
        switch event.charactersIgnoringModifiers {
        case "1": switchTo(0); return nil
        case "2": switchTo(1); return nil
        case "3": switchTo(2); return nil
        default: return event
        }
    }

    private func dismiss(_ result: String?) {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
        let cb = onChoose
        onChoose = nil
        cb?(result)
    }
}
