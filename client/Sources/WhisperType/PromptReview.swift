import Cocoa

/// One native editor for dictation and prompt variants. Drafts survive every
/// close path; inserting is explicit and names the captured destination.
final class PromptReviewController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var segments: NSSegmentedControl?
    private var draftLabel: NSTextField?
    private var keyMonitor: Any?
    private var saveTimer: Timer?
    private var names = ["Concise", "Detailed", "Coding"]
    private var levels = ["", "", ""]
    private var index = 0
    private var destination = "Choose a destination app, then return to Inbox"
    private var onChoose: ((String?) -> Void)?
    private var onDraft: (([String: String], String) throws -> Void)?
    var isVisible: Bool { panel?.isVisible == true }
    /// The caller has explicitly removed this Inbox item; do not recreate it.
    func discardOpenReview() { cleanup(nil) }
    func prepareToQuit() -> Bool { dismiss(nil) }

    func show(concise: String, detailed: String, coding: String,
              destination: String = "Choose a destination app, then return to Inbox",
              onDraft: (([String: String], String) throws -> Void)? = nil,
              onChoose: @escaping (String?) -> Void) {
        guard dismiss(nil) else { return }
        names = ["Concise", "Detailed", "Coding"]; levels = [concise, detailed, coding]; index = 0
        self.destination = destination; self.onDraft = onDraft; self.onChoose = onChoose
        present()
    }
    func showText(_ text: String, destination: String = "Choose a destination app, then return to Inbox",
                  onDraft: (([String: String], String) throws -> Void)? = nil,
                  onChoose: @escaping (String?) -> Void) {
        guard dismiss(nil) else { return }
        names = ["Result"]; levels = [text]; index = 0
        self.destination = destination; self.onDraft = onDraft; self.onChoose = onChoose
        present()
    }
    private func present() {
        buildPanel(); render()
        NSApp.activate(ignoringOtherApps: true)
        panel?.center(); panel?.makeKeyAndOrderFront(nil); panel?.makeFirstResponder(textView)
        installMonitor()
    }
    private func buildPanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        p.delegate = self; p.title = names.count > 1 ? "Review prompt" : "Review dictation"
        p.minSize = NSSize(width: 600, height: 440)
        p.isFloatingPanel = true; p.level = .floating; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        let content = NSView()
        p.contentView = content
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        let heading = NSTextField(labelWithString: names.count > 1 ? "Make it say what you mean." : "Your words, ready to use.")
        let descriptor = NSFont.systemFont(ofSize: 22, weight: .semibold).fontDescriptor.withDesign(.serif)
        heading.font = descriptor.flatMap { NSFont(descriptor: $0, size: 22) } ?? .systemFont(ofSize: 22, weight: .semibold)
        stack.addArrangedSubview(heading)
        if names.count > 1 {
            let choice = NSSegmentedControl(labels: names, trackingMode: .selectOne, target: self, action: #selector(changeVariant(_:)))
            choice.segmentStyle = .rounded; choice.selectedSegment = index
            choice.setAccessibilityLabel("Prompt version")
            stack.addArrangedSubview(choice); segments = choice
        }
        let target = NSTextField(labelWithString: "Destination: \(destination)")
        target.font = .systemFont(ofSize: 12); target.textColor = .secondaryLabelColor
        target.lineBreakMode = .byTruncatingMiddle; target.toolTip = destination
        stack.addArrangedSubview(target)
        target.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 8
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 632, height: 300))
        editor.isEditable = true; editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.drawsBackground = true; editor.backgroundColor = .textBackgroundColor; editor.textColor = .textColor
        editor.font = .systemFont(ofSize: 15); editor.textContainerInset = NSSize(width: 16, height: 16)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.delegate = self; editor.setAccessibilityLabel("Editable result")
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6
        editor.defaultParagraphStyle = paragraph
        scroll.documentView = editor; textView = editor
        stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let footer = NSStackView(); footer.orientation = .horizontal; footer.spacing = 12
        let saved = NSTextField(labelWithString: "Edits stay in Inbox")
        saved.font = .systemFont(ofSize: 11); saved.textColor = .secondaryLabelColor; draftLabel = saved
        saved.lineBreakMode = .byTruncatingTail
        footer.addArrangedSubview(saved)
        let flexible = NSView(); flexible.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(flexible)
        let keep = NSButton(title: "Keep in Inbox", target: self, action: #selector(cancelReview))
        keep.bezelStyle = .rounded; keep.keyEquivalent = "\u{1b}"
        let insert = NSButton(title: "Insert", target: self, action: #selector(insertReview))
        insert.bezelStyle = .rounded; insert.keyEquivalent = "\r"; insert.keyEquivalentModifierMask = [.command]
        insert.toolTip = "Insert into \(destination) (Command-Return)"
        footer.addArrangedSubview(keep); footer.addArrangedSubview(insert)
        stack.addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        panel = p
    }
    private func render() {
        textView?.string = levels[index]; textView?.scrollToBeginningOfDocument(nil)
        segments?.selectedSegment = index
    }
    private func saveCurrentEdits() { if let value = textView?.string { levels[index] = value } }
    @discardableResult private func persistDraft() -> Bool {
        saveTimer?.invalidate(); saveTimer = nil
        saveCurrentEdits()
        do {
            let variants = names.count > 1 ? Dictionary(uniqueKeysWithValues: zip(names.map { $0.lowercased() }, levels)) : [:]
            try onDraft?(variants, levels[index])
            draftLabel?.stringValue = "Edits saved in Inbox"; draftLabel?.textColor = .secondaryLabelColor
            return true
        } catch {
            draftLabel?.stringValue = "Could not save edits. Keep this window open."
            draftLabel?.toolTip = error.localizedDescription; draftLabel?.textColor = .systemRed
            return false
        }
    }
    func textDidChange(_ notification: Notification) {
        saveTimer?.invalidate(); draftLabel?.stringValue = "Saving edits…"
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in self?.persistDraft() }
    }
    @objc private func changeVariant(_ sender: NSSegmentedControl) { switchTo(sender.selectedSegment) }
    private func switchTo(_ value: Int) {
        guard value != index, levels.indices.contains(value) else { return }
        guard persistDraft() else { segments?.selectedSegment = index; return }
        index = value; render()
    }
    private func installMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel?.isKeyWindow == true else { return event }
            if event.keyCode == 53 { self.dismiss(nil); return nil }
            guard event.modifierFlags.contains(.command) else { return event }
            if event.keyCode == 36 || event.keyCode == 76 { self.insertReview(); return nil }
            if let character = event.charactersIgnoringModifiers, let number = Int(character), (1...3).contains(number), self.names.count > 1 {
                self.switchTo(number - 1); return nil
            }
            return event
        }
    }
    @objc private func cancelReview() { dismiss(nil) }
    @objc private func insertReview() { saveCurrentEdits(); dismiss(levels[index]) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { persistDraft() }
    func windowWillClose(_ notification: Notification) { cleanup(nil) }
    @discardableResult private func dismiss(_ result: String?) -> Bool {
        guard panel == nil || persistDraft() else { return false }
        cleanup(result); return true
    }
    private func cleanup(_ result: String?) {
        saveTimer?.invalidate(); saveTimer = nil
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        let window = panel; window?.delegate = nil; window?.orderOut(nil)
        panel = nil; textView = nil; segments = nil; draftLabel = nil
        let callback = onChoose; onChoose = nil; onDraft = nil
        window?.close(); callback?(result)
    }
}
