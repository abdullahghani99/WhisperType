import Cocoa
import SwiftUI
import AVFoundation
import ApplicationServices
import UniformTypeIdentifiers
import WhisperTypeKit

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

    // Prompt mode: dictate a rough idea → engineered prompt in a review overlay.
    // Mode (dictation vs. prompt) now lives on the dock (`dockController.state.mode`)
    // rather than a second hotkey; `promptMode` marks the in-flight recording so
    // `endRecording()` knows which path to take.
    private let promptReview = PromptReviewController()
    private var promptMode = false

    // Live meeting recorder (system audio + mic). Isolated from dictation.
    private let meetingRecorder = MeetingRecorder()
    private var meetingItem: NSMenuItem?

    private let rightOptionKeyCode: UInt16 = 61

    // Recent dictations for the menu-bar history dropdown (newest first).
    private let historyMenu = NSMenu(title: "Recent dictations")
    private var recent: [String] = []
    private let micMenu = NSMenu(title: "Microphone")   // one-click device switch

    // Last dictation, so "Correct last dictation…" can teach the server a fix.
    private var lastDictationId: Int?
    private var lastDictationText: String = ""
    private let mainWC = MainWindowController()
    private var healthTimer: Timer?

    // The floating dock: always present, shown at launch (normal path), and
    // wired to recording/mic/mode/status below. VF_OPEN_DOCK reuses this same
    // instance with stub closures for screenshot verification.
    private let dockController = DockController()

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
        // Single instance only: if another WhisperType is already running (e.g. the
        // login-agent copy plus a manual launch), bow out so there's never two.
        let bid = Bundle.main.bundleIdentifier ?? "app.whispertype.client"
        if NSRunningApplication.runningApplications(withBundleIdentifier: bid).count > 1 {
            vlog("another instance already running — exiting")
            NSApp.terminate(nil)
            return
        }
        // Preview harness (screenshot verification of DockView) — short-circuit.
        if ProcessInfo.processInfo.environment["VF_DOCK_PREVIEW"] == "1" {
            NSApp.setActivationPolicy(.regular)
            showDockPreview()
            return
        }
        // Testability harness: show the real floating DockController panel
        // (not the static preview grid) so a screenshot can verify it floats
        // above other windows, including a Screen Sharing/VNC window. Stub
        // closures only — real wiring to AudioRecorder/AppController lands
        // in a later task.
        if ProcessInfo.processInfo.environment["VF_OPEN_DOCK"] == "1" {
            NSApp.setActivationPolicy(.regular)
            showDockOpen()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        setupClient()
        setupMenu()
        requestMicPermission()
        setupHotkey()

        dockController.micDevices = { AudioDevices.inputs().map { ($0.uid, $0.name) } }
        dockController.onPickMic = { [weak self] uid in
            guard let self = self else { return }
            UserDefaults.standard.set(uid, forKey: AudioDevices.defaultsKey)
            self.recorder.reloadDevice()
            self.refreshDockMic()
        }
        dockController.onToggleMode = { [weak self] in self?.dockController.state.toggleMode() }
        dockController.onToggleRecord = { [weak self] in
            guard let self = self else { return }
            self.isRecording ? self.endRecording() : self.beginRecording(prompt: self.dockController.state.mode == .prompt)
        }
        dockController.onMeeting = { [weak self] in self?.toggleMeeting() }
        dockController.onSettings = { [weak self] in
            guard let self = self else { return }
            self.mainWC.show(client: self.client)
        }
        refreshDockMic()
        dockController.show()

        Task { await refreshHistory() }   // seed the dropdown from the server
        startHealthMonitor()
        recorder.configurePreroll()       // start warm engine if pre-roll is enabled

        // Live-apply the pre-roll toggle from Settings without a relaunch:
        // enabling starts the always-warm engine now; disabling tears it down.
        NotificationCenter.default.addObserver(
            forName: .vfPrerollChanged, object: nil, queue: .main) { [weak self] _ in
            self?.recorder.configurePreroll()
            vlog("preroll toggled -> \(UserDefaults.standard.bool(forKey: "vf_preroll"))")
        }

        // Testability: open the main window automatically (used to screenshot the UI).
        if ProcessInfo.processInfo.environment["VF_OPEN_MAIN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openMain()
                if let mid = ProcessInfo.processInfo.environment["VF_OPEN_MEETING"], let n = Int(mid) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.mainWC.meetings.open(n) }
                }
            }
        }

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
            ?? "http://127.0.0.1:8790" // set VF_SERVER_URL to your server Mac
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
        menu.addItem(NSMenuItem(title: "WhisperType — hold ⌥ (Right Option) to talk",
                                action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Dictation vs. Prompt mode on the dock",
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

        // Microphone submenu — pick your input device in one click (rebuilt on open).
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micMenu.delegate = self
        micItem.submenu = micMenu
        menu.addItem(micItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Correct last dictation… (teach a fix)",
                                action: #selector(correctLastDictation), keyEquivalent: "e"))
        menu.addItem(NSMenuItem(title: "Summarize a recording… (meeting notes)",
                                action: #selector(summarizeRecording), keyEquivalent: ""))
        let mtg = NSMenuItem(title: "Start meeting recording (live)",
                             action: #selector(toggleMeeting), keyEquivalent: "")
        menu.addItem(mtg)
        meetingItem = mtg
        menu.addItem(NSMenuItem(title: "Open WhisperType…",
                                action: #selector(openMain), keyEquivalent: "0"))
        menu.addItem(NSMenuItem(title: "Meetings…",
                                action: #selector(openMeetings), keyEquivalent: ""))
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

    @objc private func openMain() {
        mainWC.show(client: client)
    }

    @objc private func openSettings() {
        mainWC.show(client: client, section: .dictionary)
    }

    @objc private func openMeetings() {
        mainWC.show(client: client, section: .meetings)
    }

    /// Meeting mode: pick a recording, submit it for async processing, and open
    /// the Meetings window to watch/collect the result (durable server-side).
    @objc private func summarizeRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a meeting or call recording — I'll transcribe it and write notes"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let base = url.deletingPathExtension().lastPathComponent

        overlay.show(.message("Uploading “\(url.lastPathComponent)”…"))
        Task {
            do {
                let wav = try MeetingCapture.convertToWav16k(url)
                vlog("meeting: converted \(url.lastPathComponent) -> \(wav.count) wav bytes")
                let id = try await client.submitMeeting(wav: wav, title: base)
                vlog("meeting submitted: job \(id)")
                await MainActor.run {
                    self.overlay.hide()
                    self.mainWC.show(client: self.client, section: .meetings)   // watch it process
                }
            } catch {
                vlog("meeting submit FAILED: \(error)")
                await MainActor.run {
                    self.overlay.show(.message("Couldn’t read that recording: \(error.localizedDescription)"))
                    self.overlay.hide(after: 5)
                }
            }
        }
    }

    /// Start/stop live meeting recording (system audio + mic).
    @objc private func toggleMeeting() {
        if meetingRecorder.isRecording { stopMeeting() } else { startMeeting() }
    }

    private func startMeeting() {
        Task {
            do {
                try await meetingRecorder.start()
                await MainActor.run {
                    self.overlay.show(.message("🔴 Recording meeting… open the menu ▸ “Stop meeting & summarize” to finish"))
                    self.overlay.hide(after: 5)
                }
            } catch {
                vlog("meeting start FAILED: \(error)")
                await MainActor.run {
                    self.overlay.show(.message("Couldn’t start recording — grant Screen Recording in System Settings ▸ Privacy & Security, then try again"))
                    self.overlay.hide(after: 5)
                }
            }
        }
    }

    private func stopMeeting() {
        overlay.show(.message("Finishing recording…"))
        Task {
            let wav = await meetingRecorder.stop()
            guard wav.count > 8_000 else {
                await MainActor.run {
                    self.overlay.show(.message("No meeting audio captured — check Screen Recording permission"))
                    self.overlay.hide(after: 4)
                }
                return
            }
            let stamp = Self.meetingStamp.string(from: Date())
            // Save the raw recording to Desktop FIRST, so processing can never lose
            // it (re-runnable via "Summarize a recording…"). A 44-min meeting was
            // lost once before this safeguard.
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            let wavURL = desktop.appendingPathComponent("WhisperType Meeting \(stamp).wav")
            do { try wav.write(to: wavURL); vlog("meeting: audio saved -> \(wavURL.path)") }
            catch { vlog("meeting: could not save audio: \(error)") }
            do {
                // Submit for ASYNC processing — the durable server job survives even
                // if this app quits; the result appears in the Meetings window.
                let id = try await client.submitMeeting(wav: wav, title: "Meeting \(stamp)")
                vlog("meeting submitted: job \(id)")
                await MainActor.run { self.overlay.hide(); self.mainWC.show(client: self.client, section: .meetings) }
            } catch {
                vlog("meeting submit FAILED: \(error)")
                await MainActor.run {
                    self.overlay.show(.message("Recording saved to Desktop, but upload failed: \(error.localizedDescription). Retry via “Summarize a recording…”."))
                    self.overlay.hide(after: 6)
                }
            }
        }
    }

    private static let meetingStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"; return f
    }()

    /// Write notes next to the recording; fall back to the Desktop if that folder
    /// isn't writable.
    private func saveMeetingNotes(_ md: String, base: String, near url: URL) throws -> URL {
        let name = "\(base) — notes.md"
        let sibling = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try md.data(using: .utf8)!.write(to: sibling)
            return sibling
        } catch {
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(name)
            try md.data(using: .utf8)!.write(to: desktop)
            return desktop
        }
    }

    /// Teach the server a fix: show the last dictation, let the user edit it,
    /// and POST the correction. The server diffs it and derives vocab candidates
    /// (which surface in Settings ▸ Learning for approval).
    @objc private func correctLastDictation() {
        guard let id = lastDictationId else {
            overlay.show(.message("Dictate something first, then teach a correction"))
            overlay.hide(after: 2.5)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        guard let edited = CorrectionPrompt.run(prefill: lastDictationText),
              edited != lastDictationText else { return }
        Task {
            do {
                try await client.correct(id: id, edited: edited)
                vlog("correction taught for id=\(id)")
                await MainActor.run {
                    self.overlay.show(.message("Learned. Review it in Settings ▸ Learning."))
                    self.overlay.hide(after: 2.5)
                }
            } catch {
                vlog("correction FAILED: \(error)")
                await MainActor.run {
                    self.overlay.show(.message("Couldn’t save correction: \(error.localizedDescription)"))
                    self.overlay.hide(after: 3)
                }
            }
        }
    }

    // MARK: - Health monitor (menu-bar icon reflects server reachability)

    private func startHealthMonitor() {
        updateHealthIcon()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.updateHealthIcon()
        }
    }

    private func updateHealthIcon() {
        Task {
            let ok = (try? await client.health()) != nil
            await MainActor.run {
                let name = ok ? "mic.fill" : "mic.slash.fill"
                if let img = NSImage(systemSymbolName: name, accessibilityDescription: "WhisperType") {
                    img.isTemplate = true
                    self.statusItem.button?.image = img
                }
                self.statusItem.button?.toolTip = ok
                    ? "WhisperType — server reachable"
                    : "WhisperType — server unreachable"
                self.dockController.state.serverOK = ok
                self.refreshDockMic()   // keep the shown default current as mics change
            }
        }
    }

    /// Rebuild the Microphone submenu: "System default" + every input device,
    /// a checkmark on the current pin. Clicking one switches instantly.
    private func rebuildMicMenu() {
        micMenu.removeAllItems()
        let pinned = UserDefaults.standard.string(forKey: AudioDevices.defaultsKey) ?? ""
        let def = NSMenuItem(title: "System default", action: #selector(selectMic(_:)), keyEquivalent: "")
        def.target = self; def.representedObject = ""
        def.state = pinned.isEmpty ? .on : .off
        micMenu.addItem(def)
        micMenu.addItem(.separator())
        for d in AudioDevices.inputs() {
            let item = NSMenuItem(title: d.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = d.uid
            item.state = (d.uid == pinned) ? .on : .off
            micMenu.addItem(item)
        }
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        let uid = (sender.representedObject as? String) ?? ""
        UserDefaults.standard.set(uid, forKey: AudioDevices.defaultsKey)
        recorder.reloadDevice()   // apply immediately (rebuilds the warm engine)
        vlog("mic switched via menu -> \(uid.isEmpty ? "system default" : uid)")
        overlay.show(.message("Microphone: \(sender.title)"))
        overlay.hide(after: 1.5)
        refreshDockMic()
    }

    /// Reflect the mic actually in use on the dock — the LIVE default device name
    /// (e.g. "PowerConf"), not a generic "System default", so you always see which
    /// mic is active. Updated at launch, periodically, and at each recording.
    private func refreshDockMic() {
        dockController.state.micName = AudioDevices.currentInputName()
    }

    private var previewWindow: NSWindow?
    /// Renders DockView in its states for screenshot verification (VF_DOCK_PREVIEW=1).
    private func showDockPreview() {
        let idle = DockState(); idle.serverOK = true
        let listening = DockState(); listening.begin(); listening.setLevel(0.7); listening.elapsed = 8
        let controls = DockState(); controls.serverOK = true; controls.micName = "MacBook Pro Mic"
        let mics: () -> [(uid: String, name: String)] = {
            [("a", "MacBook Pro Mic"), ("b", "Beats Studio Buds"), ("c", "BlackHole 2ch")]
        }
        func mk(_ s: DockState, _ force: Bool) -> DockView {
            DockView(state: s, forceControls: force, onToggleRecord: {}, onPickMic: { _ in },
                     onToggleMode: {}, onMeeting: {}, onSettings: {}, micDevices: mics)
        }
        func row(_ label: String, _ v: some View) -> some View {
            HStack(spacing: 18) {
                Text(label).font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(white: 0.45)).frame(width: 90, alignment: .leading)
                v; Spacer()
            }
        }
        let root = VStack(alignment: .leading, spacing: 26) {
            row("AT REST", mk(idle, false))
            row("LISTENING", mk(listening, false))
            row("EXPANDED", mk(controls, true))
        }
        .padding(44)
        .frame(width: 620)
        .background(Color(red: 0.93, green: 0.92, blue: 0.90))
        let host = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: host)
        w.title = "Dock Preview"
        w.styleMask = [.titled, .closable, .resizable]
        w.setContentSize(NSSize(width: 660, height: 520))
        w.center(); w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        previewWindow = w
    }

    /// Shows the real `DockController` floating panel with stub closures, so
    /// a screenshot can confirm it floats above other windows — including a
    /// Screen Sharing/VNC session (VF_OPEN_DOCK=1). Not wired to the real
    /// recorder/AppController; that's the normal launch path below.
    private func showDockOpen() {
        dockController.state.serverOK = true
        dockController.micDevices = {
            [("a", "MacBook Pro Mic"), ("b", "Beats Studio Buds")]
        }
        dockController.onToggleRecord = { vlog("[VF_OPEN_DOCK] onToggleRecord (stub)") }
        dockController.onPickMic = { uid in vlog("[VF_OPEN_DOCK] onPickMic(\(uid)) (stub)") }
        dockController.onToggleMode = { vlog("[VF_OPEN_DOCK] onToggleMode (stub)") }
        dockController.onMeeting = { vlog("[VF_OPEN_DOCK] onMeeting (stub)") }
        dockController.onSettings = { vlog("[VF_OPEN_DOCK] onSettings (stub)") }
        dockController.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - Recent dictations dropdown

    func menuWillOpen(_ menu: NSMenu) {
        // Refresh the cache from the server when the main menu opens.
        if menu !== historyMenu {
            Task { await refreshHistory() }
            meetingItem?.title = meetingRecorder.isRecording
                ? "Stop meeting & summarize"
                : "Start meeting recording (live)"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === micMenu { rebuildMicMenu(); return }
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
        // Single hotkey (Right-Option, hold to talk); which mode (dictation vs.
        // prompt) it records in is decided by `dockController.state.mode`, not
        // by which key is held.
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            guard event.keyCode == self.rightOptionKeyCode else { return }
            let pressed = event.modifierFlags.contains(.option)
            if pressed {
                self.beginRecording(prompt: self.dockController.state.mode == .prompt)
            } else {
                self.endRecording()
            }
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
        if isRecording { endRecording() } else { beginRecording(prompt: dockController.state.mode == .prompt) }
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

    private func beginRecording(prompt: Bool = false) {
        guard !isRecording else { return }
        // Enter recording state optimistically and show the overlay immediately —
        // recorder.start() is now async (engine bring-up is off the main thread so
        // a slow/Bluetooth mic can't freeze the app). If the mic genuinely fails,
        // the completion resets state and shows the error.
        isRecording = true
        promptMode = prompt
        // The DOCK is the sole live indicator now — do NOT also show the old
        // overlay pill (that was the "two waveforms" during dictation).
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.dockController.state.setLevel(level) }
        }
        dockController.state.begin()
        SoundFeedback.listening()   // light "ting" so you know it's live
        vlog("recording: start (prompt=\(prompt))")
        recorder.start { [weak self] ok in
            guard let self = self, !ok, self.isRecording else { return }
            self.isRecording = false
            vlog("recorder failed to start (mic unavailable)")
            self.overlay.show(.message("Microphone unavailable — check input device / other apps"))
            self.overlay.hide(after: 2.5)
            self.dockController.state.fail("Microphone unavailable")
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        let wasPrompt = promptMode
        let wav = recorder.stop()
        vlog("recording: stop, wav bytes=\(wav.count) prompt=\(wasPrompt)")
        dockController.state.finishRecording()

        guard wav.count > 8_000 else {
            if wav.count <= 64 {  // header only → the mic produced no samples
                vlog("no audio captured (mic produced no samples)")
                // FALLBACK: the current mic yielded nothing (a Bluetooth mic asleep,
                // or a device that isn't the one you're speaking into). Do NOT force
                // built-in (over Screen Sharing the built-in mic is often silent).
                // Instead CYCLE to the next real input device, so consecutive tries
                // land on whichever mic actually has your voice (e.g. the PowerConf).
                let inputs = AudioDevices.inputs()
                let current = AudioDevices.resolvedInputUID()
                if inputs.count > 1 {
                    let idx = inputs.firstIndex { $0.uid == current } ?? -1
                    let next = inputs[(idx + 1) % inputs.count]
                    UserDefaults.standard.set(next.uid, forKey: AudioDevices.defaultsKey)
                    recorder.reloadDevice()
                    refreshDockMic()
                    vlog("no audio — cycled mic to \(next.name) (\(next.uid))")
                    dockController.state.fail("No audio — trying “\(next.name)”")
                } else {
                    dockController.state.fail("No audio captured")
                }
            } else {
                vlog("recording too short, ignoring")
                dockController.state.returnToIdle()
            }
            return
        }

        // Capture the target app BEFORE the panel steals focus.
        let targetApp = NSWorkspace.shared.frontmostApplication

        // The dock is the sole indicator (finishRecording above → "Polishing…").
        // No overlay pills here — that was the second pill.
        if wasPrompt {
            Task { await runPromptMode(wav: wav, targetApp: targetApp) }
            return
        }

        Task {
            do {
                let result = try await client.transcribe(wav: wav)
                vlog("transcribe ok: id=\(result.id.map(String.init) ?? "nil") raw=\"\(result.raw)\" text=\"\(result.text)\"")
                await MainActor.run {
                    self.addToHistory(result.text)
                    self.lastDictationId = result.id
                    self.lastDictationText = result.text
                }
                await insert(result.text)
                await MainActor.run {
                    self.dockController.state.complete()
                    SoundFeedback.done()   // soft confirm when your text lands
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        // Guard: a fast back-to-back dictation may have already
                        // started a new recording — don't clobber it to idle.
                        if self.dockController.state.phase == .done {
                            self.dockController.state.returnToIdle()
                        }
                    }
                }
            } catch {
                vlog("transcribe FAILED: \(error)")
                await MainActor.run { self.dockController.state.fail("Couldn’t reach server") }
            }
        }
    }

    /// Prompt mode: engineer the rough dictation into concise/detailed prompts,
    /// show the review overlay, and insert the chosen one into `targetApp`.
    private func runPromptMode(wav: Data, targetApp: NSRunningApplication?) async {
        do {
            let eng = try await client.engineer(wav: wav)
            vlog("engineer ok: concise=\(eng.concise.count)ch detailed=\(eng.detailed.count)ch")
            await MainActor.run {
                self.dockController.state.complete()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.dockController.state.returnToIdle()
                }
                guard !eng.concise.isEmpty || !eng.detailed.isEmpty || !eng.coding.isEmpty else {
                    self.dockController.state.fail("No prompt generated"); return
                }
                self.promptReview.show(concise: eng.concise, detailed: eng.detailed, coding: eng.coding) { [weak self] chosen in
                    guard let self = self else { return }
                    targetApp?.activate(options: [])   // restore focus to where the caret was
                    guard let text = chosen, !text.isEmpty else { return }   // esc → nothing typed
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        Task { await self.insert(text) }
                    }
                }
            }
        } catch {
            vlog("engineer FAILED: \(error)")
            await MainActor.run { self.dockController.state.fail("Prompt mode failed") }
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
