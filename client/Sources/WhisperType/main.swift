import Cocoa
import AVFoundation
import ApplicationServices

/// Simple timestamped file log so we can diagnose the live pipeline.
/// tail -f /tmp/whispertype-client.log
func vlog(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    let path = "/tmp/whispertype-client.log"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
    }
}

/// WhisperType menu-bar client.
///
/// Push-to-talk: hold Right-Option (⌥) to record, release to transcribe and
/// insert via synthesized keystrokes (works over Screen Sharing / VNC).
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let recorder = AudioRecorder()
    private let overlay = OverlayController()
    private var client: ServerClient!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isRecording = false

    private let rightOptionKeyCode: UInt16 = 61

    // Recent dictations for the menu-bar history dropdown (newest first).
    private let historyMenu = NSMenu(title: "Recent dictations")
    private var recent: [String] = []
    private let settingsWC = SettingsWindowController()

    // Optional mouse-button TOGGLE trigger (e.g. a Logitech side/scroll button):
    // click to start, click again to stop. Coexists with Right-Option (hold).
    // A CGEventTap is used (not an NSEvent monitor) so we can CONSUME the click
    // — otherwise the button's native action (e.g. middle-click paste) also fires.
    private var eventTap: CFMachPort?
    private var capturingMouseTrigger = false
    private var lastToggle = Date.distantPast
    private var mouseToggleButton: Int {
        get { UserDefaults.standard.object(forKey: "vf_mouseToggleButton") as? Int ?? -1 }
        set { UserDefaults.standard.set(newValue, forKey: "vf_mouseToggleButton") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        vlog("=== WhisperType client launched ===")
        NSApp.setActivationPolicy(.accessory)
        setupClient()
        setupMenu()
        requestMicPermission()
        setupHotkey()

        Task { await refreshHistory() }   // seed the dropdown from the server

        let trusted = AXIsProcessTrusted()
        vlog("accessibility trusted at launch: \(trusted)")
        if !trusted {
            ensureAccessibilityPrompt()
            overlay.show(.message("Enable WhisperType in Privacy & Security ▸ Accessibility, then relaunch"))
            overlay.hide(after: 8)
        }
    }

    // MARK: - Config

    private func setupClient() {
        let urlStr = ProcessInfo.processInfo.environment["VF_SERVER_URL"]
            ?? "http://127.0.0.1:8790" // set VF_SERVER_URL to your server Mac (Tailscale IP)
        let apiKey = ProcessInfo.processInfo.environment["VF_API_KEY"]
        client = ServerClient(baseURL: URL(string: urlStr)!, apiKey: apiKey)
        vlog("server url: \(urlStr)")
        Task {
            do { vlog("startup health check: \(try await client.health())") }
            catch { vlog("startup health check FAILED: \(error)") }
        }
    }

    // MARK: - Menu bar

    private func setupMenu() {
        if let img = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "WhisperType") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "VF"
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "WhisperType — hold ⌥ (Right Option) to dictate",
                                action: nil, keyEquivalent: ""))

        // Mouse-button toggle trigger
        let trig = mouseToggleButton >= 0
            ? "Mouse trigger: button \(mouseToggleButton) (click to start/stop)"
            : "Mouse trigger: not set"
        let trigInfo = NSMenuItem(title: trig, action: nil, keyEquivalent: "")
        trigInfo.isEnabled = false
        menu.addItem(trigInfo)
        menu.addItem(NSMenuItem(title: "Set mouse trigger…",
                                action: #selector(setMouseTrigger), keyEquivalent: ""))
        if mouseToggleButton >= 0 {
            menu.addItem(NSMenuItem(title: "Clear mouse trigger",
                                    action: #selector(clearMouseTrigger), keyEquivalent: ""))
        }
        menu.addItem(.separator())

        // Recent dictations submenu — rebuilt on open (menuNeedsUpdate).
        let historyItem = NSMenuItem(title: "Recent dictations", action: nil, keyEquivalent: "")
        historyMenu.delegate = self
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Settings & Dictionary…",
                                action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Test dictation now (5s)",
                                action: #selector(testDictation), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Insert test string (focus target first)",
                                action: #selector(insertTestString), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Accessibility settings…",
                                action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Deterministic diagnostic: types a fixed string covering capitals and
    /// shifted punctuation. Focus the target field (local or VNC), then pick this
    /// — a short delay lets the menu close and key focus return to that field.
    @objc private func insertTestString() {
        let s = "Hello world! What's the plan? Testing 1, 2, 3: 100% ready."
        vlog("insert test string")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            KeystrokeInserter.type(s)
        }
    }

    @objc private func openSettings() {
        settingsWC.show(client: client)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - Recent dictations dropdown

    func menuWillOpen(_ menu: NSMenu) {
        // Refresh the cache from the server when the main menu opens.
        if menu !== historyMenu { Task { await refreshHistory() } }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === historyMenu else { return }
        menu.removeAllItems()
        guard !recent.isEmpty else {
            let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let hint = NSMenuItem(title: "Click any to copy", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        for text in recent.prefix(15) {
            let one = text.replacingOccurrences(of: "\n", with: " ")
            let title = one.count > 64 ? String(one.prefix(64)) + "…" : one
            let item = NSMenuItem(title: title, action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
            item.representedObject = text
            item.target = self
            item.toolTip = text
            menu.addItem(item)
        }
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        overlay.show(.message("Copied to clipboard"))
        overlay.hide(after: 1.2)
    }

    private func refreshHistory() async {
        if let items = try? await client.recent(limit: 15) {
            await MainActor.run { self.recent = items }
        }
    }

    private func addToHistory(_ text: String) {
        guard !text.isEmpty else { return }
        recent.insert(text, at: 0)
        if recent.count > 30 { recent.removeLast(recent.count - 30) }
    }

    /// Menu-triggered test: record 5 seconds without the hotkey (useful when
    /// Accessibility isn't granted yet — the menu click works regardless).
    @objc private func testDictation() {
        vlog("menu test dictation: begin")
        beginRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.endRecording() }
    }

    // MARK: - Permissions

    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            vlog("microphone permission granted: \(granted)")
        }
    }

    private func ensureAccessibilityPrompt() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Hotkey (push-to-talk on Right Option)

    private func setupHotkey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self, event.keyCode == self.rightOptionKeyCode else { return }
            let pressed = event.modifierFlags.contains(.option)
            if pressed { self.beginRecording() } else { self.endRecording() }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            handler(event); return event
        }

        setupMouseTap()
        vlog("hotkey monitors installed (global=\(globalMonitor != nil)) mouseToggleButton=\(mouseToggleButton)")
    }

    /// CGEventTap for mouse-button toggle — can CONSUME the click so the button's
    /// native action (middle-click paste, side-button back/forward) doesn't fire.
    private func setupMouseTap() {
        let mask = (UInt64(1) << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let ctrl = Unmanaged<AppController>.fromOpaque(userInfo).takeUnretainedValue()
            return ctrl.handleMouseTap(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            vlog("failed to create mouse event tap (needs Accessibility)")
            return
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        vlog("mouse event tap installed")
    }

    /// Called on the main run loop from the CGEventTap. Return nil to consume.
    func handleMouseTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .otherMouseDown else { return Unmanaged.passUnretained(event) }
        let btn = Int(event.getIntegerValueField(.mouseEventButtonNumber))

        if capturingMouseTrigger {
            capturingMouseTrigger = false
            mouseToggleButton = btn
            overlay.show(.message("Trigger set: mouse button \(btn). Click it to start/stop dictation."))
            overlay.hide(after: 3)
            setupMenu()
            vlog("mouse trigger set to button \(btn)")
            return nil   // consume the capture click
        }
        if mouseToggleButton >= 0 && btn == mouseToggleButton {
            toggleRecording()
            return nil   // consume → no native middle/side-click action
        }
        return Unmanaged.passUnretained(event)
    }

    private func toggleRecording() {
        // Debounce so one physical click = one toggle (no desync from double-fire).
        let now = Date()
        if now.timeIntervalSince(lastToggle) < 0.25 { return }
        lastToggle = now
        if isRecording { endRecording() } else { beginRecording() }
    }

    @objc private func setMouseTrigger() {
        capturingMouseTrigger = true
        overlay.show(.message("Click the mouse button you want to use as your dictation trigger…"))
        overlay.hide(after: 6)
    }

    @objc private func clearMouseTrigger() {
        mouseToggleButton = -1
        setupMenu()
        overlay.show(.message("Mouse trigger cleared"))
        overlay.hide(after: 1.5)
    }

    // MARK: - Record → transcribe → insert

    private func beginRecording() {
        guard !isRecording else { return }
        recorder.onLevel = { [weak self] level in self?.overlay.state.pushLevel(level) }
        recorder.start()
        // Only enter recording state if the mic actually started — otherwise the
        // state would get stuck "true" and the next click would wrongly STOP.
        guard recorder.isRecording else {
            vlog("recorder failed to start (mic unavailable)")
            overlay.show(.message("Microphone unavailable — check input device / other apps"))
            overlay.hide(after: 2.5)
            return
        }
        isRecording = true
        overlay.show(.listening)
        vlog("recording: start")
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        let wav = recorder.stop()
        vlog("recording: stop, wav bytes=\(wav.count)")

        guard wav.count > 8_000 else {
            vlog("recording too short, ignoring")
            overlay.hide()
            return
        }

        overlay.show(.transcribing)
        Task {
            do {
                let result = try await client.transcribe(wav: wav)
                vlog("transcribe ok: raw=\"\(result.raw)\" text=\"\(result.text)\"")
                await MainActor.run { self.addToHistory(result.text) }
                await insert(result.text)
                overlay.hide(after: 0.4)
            } catch {
                vlog("transcribe FAILED: \(error)")
                overlay.show(.message("Couldn’t reach server: \(error.localizedDescription)"))
                overlay.hide(after: 4)
            }
        }
    }

    /// Route insertion: if the frontmost app is Screen Sharing, synthetic
    /// modifiers can't cross the VNC boundary, so send the text to the remote
    /// agent on the target Mac (it types locally there). Otherwise type locally.
    private func insert(_ text: String) async {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let isScreenSharing = front == "com.apple.ScreenSharing" || front.contains("ScreenSharing")
        if isScreenSharing, let url = remoteAgentURL {
            do {
                try await postRemoteInsert(text, to: url)
                vlog("inserted via remote agent (frontmost=\(front))")
                return
            } catch {
                vlog("remote insert FAILED (\(error)); falling back to local")
                overlay.show(.message("Remote agent unreachable — typed locally"))
                overlay.hide(after: 3)
            }
        }
        await MainActor.run { KeystrokeInserter.type(text) }
    }

    private var remoteAgentURL: URL? {
        let s = ProcessInfo.processInfo.environment["VF_REMOTE_AGENT_URL"]
            ?? "http://127.0.0.1:8791" // set VF_REMOTE_AGENT_URL to the Mac you screen-share into
        return URL(string: s)?.appendingPathComponent("insert")
    }

    private func postRemoteInsert(_ text: String, to url: URL) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        req.timeoutInterval = 15
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "whispertype", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "agent HTTP error"])
        }
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
