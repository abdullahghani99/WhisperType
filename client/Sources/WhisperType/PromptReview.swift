import Cocoa

/// Interactive review panel for prompt mode. Shows the engineered prompt and
/// lets the user flip Concise/Detailed (1/2), insert it (⏎), or cancel (esc).
/// Non-destructive: nothing is typed until the user chooses to insert.
///
/// The panel becomes key so a local key monitor can capture 1/2/⏎/esc; the
/// caller is responsible for restoring focus to the target app before typing.
final class PromptReviewController {
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var levelLabel: NSTextField?
    private var keyMonitor: Any?

    private var concise = ""
    private var detailed = ""
    private var showingDetailed = false
    private var onChoose: ((String?) -> Void)?   // chosen text to insert, or nil = cancel

    private static let ink = NSColor(calibratedRed: 0x1A/255, green: 0x17/255, blue: 0x14/255, alpha: 0.98)
    private static let accent = NSColor(calibratedRed: 0xE7/255, green: 0x00/255, blue: 0x0B/255, alpha: 1)

    private var current: String { showingDetailed ? detailed : concise }

    /// Show the panel. `onChoose` is called exactly once with the chosen text,
    /// or nil if the user cancelled.
    func show(concise: String, detailed: String, onChoose: @escaping (String?) -> Void) {
        self.concise = concise
        self.detailed = detailed
        self.showingDetailed = false
        self.onChoose = onChoose
        buildPanel()
        render()
        NSApp.activate(ignoringOtherApps: true)
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        installMonitor()
    }

    private func buildPanel() {
        if panel != nil { return }
        let w: CGFloat = 640, h: CGFloat = 420
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "Prompt — review"
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.backgroundColor = Self.ink

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let header = NSTextField(labelWithString: "Engineered prompt")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .white
        header.frame = NSRect(x: 20, y: h - 52, width: 300, height: 20)
        content.addSubview(header)

        let level = NSTextField(labelWithString: "")
        level.font = .systemFont(ofSize: 12, weight: .medium)
        level.alignment = .right
        level.frame = NSRect(x: w - 320, y: h - 52, width: 300, height: 20)
        content.addSubview(level)
        levelLabel = level

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 48, width: w - 32, height: h - 108))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textColor = NSColor(white: 0.95, alpha: 1)
        tv.font = .systemFont(ofSize: 14)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = tv
        content.addSubview(scroll)
        textView = tv

        let footer = NSTextField(labelWithString: "1  Concise      2  Detailed      ⏎  Insert      esc  Cancel")
        footer.font = .systemFont(ofSize: 12, weight: .regular)
        footer.textColor = NSColor(white: 0.65, alpha: 1)
        footer.alignment = .center
        footer.frame = NSRect(x: 16, y: 16, width: w - 32, height: 18)
        footer.autoresizingMask = [.width, .minYMargin]
        content.addSubview(footer)

        p.contentView = content
        panel = p
    }

    private func render() {
        textView?.string = current
        textView?.scrollToBeginningOfDocument(nil)
        let attr = NSMutableAttributedString()
        let on: [NSAttributedString.Key: Any] = [.foregroundColor: Self.accent,
                                                 .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
        let off: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor(white: 0.55, alpha: 1),
                                                  .font: NSFont.systemFont(ofSize: 12)]
        attr.append(NSAttributedString(string: "Concise", attributes: showingDetailed ? off : on))
        attr.append(NSAttributedString(string: "   /   ", attributes: off))
        attr.append(NSAttributedString(string: "Detailed", attributes: showingDetailed ? on : off))
        levelLabel?.attributedStringValue = attr
    }

    private func installMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53:  // esc
            dismiss(nil); return nil
        case 36, 76:  // return / keypad enter
            dismiss(current); return nil
        default:
            break
        }
        switch event.charactersIgnoringModifiers {
        case "1": showingDetailed = false; render(); return nil
        case "2": showingDetailed = true; render(); return nil
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
