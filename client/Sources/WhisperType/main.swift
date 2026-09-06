import Darwin
import Cocoa
import SwiftUI
import AVFoundation
import ApplicationServices
import UniformTypeIdentifiers
import CoreText
import WhisperTypeKit

/// Simple timestamped file log so we can diagnose the live pipeline.
/// tail -f /tmp/whispertype-client.log
private let voiceFlowLogLock = NSLock()
func vlog(_ s: String) {
    voiceFlowLogLock.lock(); defer { voiceFlowLogLock.unlock() }
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    let path = ProcessInfo.processInfo.environment["VF_LOG_PATH"] ?? "/tmp/whispertype-client.log"
    let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else { return }
    defer { Darwin.close(fd) }
    line.data(using: .utf8)!.withUnsafeBytes { bytes in
        _ = Darwin.write(fd, bytes.baseAddress!, bytes.count)
    }
}

/// whispertype menu-bar client.
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
    private var activeRecordingID: UUID?
    private var recordingStoppedAt: [UUID: TimeInterval] = [:]
    private var captureDestination: CaptureDestination?
    private var lastExternalDestination: CaptureDestination?
    private var presentationID: UUID?
    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    private var processingTail: Task<Void, Never>?
    private var terminationPending = false
    private var unsavedRecordings: [UUID: (audio: Data, entry: RecordingStore.Entry)] = [:]
    private var reviewedRecordingID: UUID?
    private var importTask: Task<Void, Never>?
    private var meetingAttemptID: UUID?
    private var meetingFinishing = false
    private var destinations: [UUID: CaptureDestination] = [:]
    private var meetingStarting = false
    private var meetingFromCall = false
    private var mouseLearningTimer: Timer?

    // Prompt mode: dictate a rough idea → engineered prompt in a review overlay.
    // Mode (dictation vs. prompt) now lives on the dock (`dockController.state.mode`)
    // rather than a second hotkey; `promptMode` marks the in-flight recording so
    // `endRecording()` knows which path to take.
    private let promptReview = PromptReviewController()
    private var promptMode = false

    // Live meeting recorder (system audio + mic). Isolated from dictation.
    private let meetingRecorder = MeetingRecorder()
    private let callWatcher = CallWatcher()
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

    /// Register the bundled Inter faces so the design system can use them. Never
    /// blocks launch: if the resources are missing or registration fails, the
    /// design system falls back to the system sans and the app renders normally.
    private func registerFonts() {
        let names = ["Inter-Regular", "Inter-Medium", "Inter-SemiBold"]
        var registered = 0
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                    ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Resources")
            else { continue }
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) {
                registered += 1
            }
        }
        VF.Font.interAvailable = (registered == names.count)
        vlog("fonts: Inter registered=\(registered)/\(names.count) available=\(VF.Font.interAvailable)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerFonts()
        vlog("=== whispertype client launched ===")
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
        if ProcessInfo.processInfo.environment["VF_CALL_OFFER"] == "1" {
            // Screenshot harness for the ambient call offer.
            dockController.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let raw = ProcessInfo.processInfo.environment["VF_CALL_APP"] ?? "Microsoft Teams ModuleHost"
                self.dockController.state.callTitle = CallSource.offerTitle(for: raw)
                if let app = NSWorkspace.shared.runningApplications.first(where: {
                    ($0.localizedName ?? "").localizedCaseInsensitiveContains(CallSource.friendlyName(raw))
                }), let icon = app.icon, let tiff = icon.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff) {
                    self.dockController.state.callIconPNG = rep.representation(using: .png, properties: [:])
                }
                self.dockController.state.callOffer = true
            }
            return
        }
        if ProcessInfo.processInfo.environment["VF_OPEN_DOCK"] == "1" {
            NSApp.setActivationPolicy(.regular)
            showDockOpen()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        vlog("accessibility trusted before setup: \(AXIsProcessTrusted())")
        setupClient()
        setupMenu()
        setupHotkey()

        // Follow the system input device. Without this the engine outlives the
        // hardware it was built for.
        AudioDevices.onDefaultInputChanged { [weak self] in
            guard let self = self else { return }
            // Changing the input in macOS IS a device choice, and it must win.
            // A pin ranks ahead of the system default, so a mic picked here once
            // kept being forced forever: switch to the speakerphone and WhisperType
            // carried on recording AirPods that were sitting in their case, which
            // is what "it records nothing when I change devices" actually was.
            // An explicit pin stays explicit. System changes affect follow-system
            // selection and fallback availability, not the saved user choice.
            vlog("system input changed -> \(AudioDevices.currentInputName()) — rebuilding engine")
            self.recorder.reloadDevice()
            self.refreshDockMic()
        }

        dockController.micDevices = { AudioDevices.inputs().map { ($0.uid, $0.name) } }
        dockController.onPickMic = { [weak self] uid in
            guard let self = self else { return }
            self.mainWC.settings.selectMic(uid)
            self.refreshDockMic()
        }
        dockController.onToggleMode = { [weak self] in
            guard let self = self else { return }
            self.dockController.state.toggleMode()
            self.mainWC.settings.captureMode = self.dockController.state.mode
        }
        dockController.onToggleRecord = { [weak self] in
            guard let self = self else { return }
            self.isRecording ? self.endRecording() : self.beginRecording(prompt: self.dockController.state.mode == .prompt, trigger: "pill")
        }
        dockController.onMeeting = { [weak self] in self?.toggleMeeting() }
        dockController.onAcceptCall = { [weak self] in self?.startMeeting(fromCall: true) }
        dockController.onSettings = { [weak self] in
            guard let self = self else { return }
            self.mainWC.show(client: self.client)
        }
        wireClientExperience()
        refreshDockMic()
        if ProcessInfo.processInfo.environment["VF_VALIDATION_HIDE_DOCK"] != "1" { dockController.show() }

        Task { await refreshHistory() }   // seed the dropdown from the server
        startHealthMonitor()
        // Default pre-roll ON. Without a warm engine every press pays the mic's
        // wake-up delay, which is why short dictations came back empty while long
        // ones worked. The trade is that the microphone is live while WhisperType
        // runs — visible in the macOS recording indicator, and switchable in
        // Settings ▸ Microphone. Nothing is stored: the pre-roll is 1.5s held in
        // memory and overwritten continuously.
        UserDefaults.standard.register(defaults: ["vf_preroll": true])
        if ProcessInfo.processInfo.environment["VF_VALIDATION"] == "1" { vlog("input diagnostics at launch: " + AudioDevices.inputMuteSummary(AudioDevices.preferredInput())) }
        if ProcessInfo.processInfo.environment["VF_VALIDATION"] != "1", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { recorder.configurePreroll() }

        // Ambient meetings: offer to record when a call starts, and stop by
        // itself when it ends. Two meetings were lost to "I forgot to press
        // record" and "I forgot to press stop"; this closes both.
        callWatcher.isOurEngineRunning = { [weak self] in self?.recorder.isEngineRunning ?? false }
        callWatcher.onCallStarted = { [weak self] in
            guard let self = self else { return }
            // Never interrupt a recording that is already running.
            guard !self.meetingRecorder.isRecording else { return }
            let raw = self.callWatcher.lastCallSource
            vlog("call detected via \(raw) — offering to record")
            self.dockController.state.callTitle = CallSource.offerTitle(for: raw)
            self.dockController.state.callIconPNG = self.callWatcher.lastCallIconPNG
            // Announce ONCE per offer. The detector can report a start twice as a
            // device settles, and two chimes for one call reads as a glitch.
            let alreadyOffering = self.dockController.state.callOffer
            self.dockController.state.callOffer = true
            if !alreadyOffering { SoundFeedback.callOffer() }
            // The offer stays for as long as the call does. A 12-second window
            // assumed the human was watching the screen at the exact moment a
            // call began — usually they are looking at the person, or reaching
            // for headphones. It disappears when the call ends, or when
            // dismissed, and never nags beyond that.
        }
        callWatcher.onCallEnded = { [weak self] in
            guard let self = self else { return }
            vlog("call ended")
            self.dockController.state.callOffer = false
            guard self.meetingRecorder.isRecording, self.meetingFromCall else { return }
            vlog("call ended — stopping the meeting recording automatically")
            self.stopMeeting()
        }
        if ProcessInfo.processInfo.environment["VF_VALIDATION"] != "1" { callWatcher.start() }

        // Live-apply the pre-roll toggle from Settings without a relaunch:
        // enabling starts the always-warm engine now; disabling tears it down.
        NotificationCenter.default.addObserver(
            forName: .vfPrerollChanged, object: nil, queue: .main) { [weak self] _ in
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { self?.recorder.configurePreroll() }
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
            if ProcessInfo.processInfo.environment["VF_VALIDATION"] != "1" { refreshPermissions() }
            overlay.show(.message("Enable WhisperType in Privacy & Security ▸ Accessibility, then return to WhisperType"))
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
        if let img = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "whispertype") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "VF"
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "whispertype — hold ⌥ (Right Option) to talk",
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
        menu.addItem(NSMenuItem(title: "Focus recording controls", action: #selector(focusRecordingControls), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open WhisperType…",
                                action: #selector(openMain), keyEquivalent: "0"))
        menu.addItem(NSMenuItem(title: "Meetings…",
                                action: #selector(openMeetings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show recordings folder",
                                action: #selector(showRecordingsFolder), keyEquivalent: ""))
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

    /// Reveal the meeting-recordings folder in Finder (it lives under ~/Library,
    /// which Finder hides by default).
    @objc private func showRecordingsFolder() {
        NSWorkspace.shared.open(Self.recordingsDir())
    }

    /// Deterministic diagnostic: types a fixed string covering capitals and
    /// shifted punctuation. Focus the target field (local or VNC), then pick this
    /// — a short delay lets the menu close and key focus return to that field.
    @objc private func insertTestString() {
        let s = "Hello Alex! What's the plan? ERP42, B2B: 100% ready."
        vlog("insert test string")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let target = CaptureDestination.capture() else { return }
            Task { @MainActor in
                do {
                    let id = UUID()
                    if target.isRemote { try await self.prepareRemote(target, id: id) }
                    try await self.insert(s, into: target, id: id)
                } catch { self.mainWC.settings.status = error.localizedDescription }
            }
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
        guard importTask == nil else { mainWC.show(client: client, section: .capture); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a meeting or call recording — I'll transcribe it and write notes"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let base = url.deletingPathExtension().lastPathComponent

        mainWC.settings.importing = true
        mainWC.settings.importStatus = "Reading \(url.lastPathComponent)…"
        mainWC.show(client: client, section: .capture)
        importTask = Task { @MainActor in
            defer { self.importTask = nil; self.mainWC.settings.importing = false }
            do {
                let conversion = Task.detached { try MeetingCapture.convertToWav16k(url) }
                let wav = try await withTaskCancellationHandler(operation: { try await conversion.value }, onCancel: { conversion.cancel() })
                try Task.checkCancellation()
                vlog("meeting: converted \(url.lastPathComponent) -> \(wav.count) wav bytes")
                self.mainWC.settings.importStatus = "Uploading recording…"
                let id = try await client.submitMeeting(wav: wav, title: base)
                vlog("meeting submitted: job \(id)")
                self.mainWC.settings.importStatus = "Recording accepted. Processing continues in Meetings."
                await MainActor.run {
                    self.overlay.hide()
                    self.mainWC.show(client: self.client, section: .meetings)   // watch it process
                }
            } catch {
                let canceled = error is CancellationError || (error as? URLError)?.code == .cancelled
                self.mainWC.settings.importStatus = canceled
                    ? "Import canceled. Your original recording is unchanged. If upload had started, check Meetings before retrying."
                    : "Import failed: \(error.localizedDescription). Your original recording is unchanged."
                vlog("meeting submit FAILED: \(error)")
                await MainActor.run {
                    self.overlay.show(.message(canceled ? "Import canceled" : "Couldn’t read that recording: \(error.localizedDescription)"))
                    self.overlay.hide(after: 5)
                }
            }
        }
    }

    /// Start/stop live meeting recording (system audio + mic).
    @objc private func toggleMeeting() {
        if meetingRecorder.isRecording || meetingRecorder.isStarting || meetingStarting { stopMeeting() } else { startMeeting() }
    }

    private func startMeeting(fromCall: Bool = false) {
        guard !terminationPending, !isRecording, !meetingStarting, !meetingFinishing, !meetingRecorder.isRecording else { return }
        let attempt = UUID(); meetingAttemptID = attempt
        meetingStarting = true
        meetingFromCall = fromCall && dockController.state.callOffer
        mainWC.settings.captureStatus = "Starting meeting…"
        Task {
            let available = await withCheckedContinuation { continuation in
                recorder.suspendForMeeting { continuation.resume(returning: $0) }
            }
            guard self.meetingAttemptID == attempt else { return }
            guard available else {
                await MainActor.run {
                    self.meetingStarting = false; self.recorder.resumeAfterMeeting()
                    self.mainWC.settings.captureStatus = "Microphone is busy. Retry when capture finishes."
                }
                return
            }
            do {
                // A refused start must not light the recording indicator. It used
                // to show red while nothing whatsoever was being captured.
                guard self.meetingStarting else { self.recorder.resumeAfterMeeting(); return }
                let began = try await meetingRecorder.start()
                guard self.meetingAttemptID == attempt else { return }
                guard began else {
                    await MainActor.run {
                        self.meetingStarting = false; self.recorder.resumeAfterMeeting()
                        self.overlay.show(.message("A meeting is still finishing — try again in a moment."))
                        self.overlay.hide(after: 3)
                    }
                    return
                }
                await MainActor.run {
                    self.meetingStarting = false
                    self.mainWC.settings.meetingCapturing = true
                    self.mainWC.settings.activeJournal = self.meetingRecorder.journalDirectory
                    self.mainWC.settings.captureStatus = "Recording meeting"
                    self.refreshDockMic()
                    self.dockController.state.meetingElapsed = 0
                    self.dockController.state.meetingRecording = true
                    self.dockController.state.callOffer = false
                    // Tell the truth up front. A meeting that records only the
                    // other participants is worse than one that fails outright —
                    // you find out an hour later, when the audio is gone.
                    // Installed for EVERY meeting, not just ones that started with
                    // a working mic. It used to live inside the micLive branch, so
                    // the case that matters most -- no microphone at all -- never
                    // heard about the retries or about them being given up on.
                    self.meetingRecorder.onMicTrouble = { [weak self] msg in
                        guard let self = self else { return }
                        SoundFeedback.failed()
                        self.overlay.show(.message("⚠️ \(msg)"))
                        self.overlay.hide(after: 8)
                        // Sticky, unlike the overlay: the dock's recording dot
                        // turns amber and STAYS amber until the mic comes back.
                        // (Setting errorText alone rendered nothing — it is only
                        // drawn in the .error phase — and left stale text behind.)
                        self.dockController.state.meetingMicTrouble = true
                    }
                    self.meetingRecorder.onMicRecovered = { [weak self] in
                        self?.dockController.state.meetingMicTrouble = false
                        self?.overlay.show(.message("Microphone is being picked up again."))
                        self?.overlay.hide(after: 3)
                    }
                    if self.meetingRecorder.micLive {
                        self.overlay.show(.message("🔴 Recording meeting (mic: \(self.meetingRecorder.micName)) — menu ▸ “Stop meeting & summarize” to finish"))
                        self.overlay.hide(after: 5)
                    } else {
                        self.overlay.show(.message("⚠️ Recording, but NO working microphone — only other participants will be captured. Pick a mic in Settings and restart the recording."))
                        self.overlay.hide(after: 12)
                    }
                }
            } catch {
                guard self.meetingAttemptID == attempt else { return }
                vlog("meeting start FAILED: \(error)")
                await MainActor.run {
                    self.meetingStarting = false; self.recorder.resumeAfterMeeting()
                    self.mainWC.settings.meetingCapturing = false
                    self.dockController.state.meetingRecording = false
                    self.dockController.state.meetingMicTrouble = false
                    self.overlay.show(.message("Couldn’t start recording — grant Screen Recording in System Settings ▸ Privacy & Security, then try again"))
                    self.overlay.hide(after: 5)
                }
            }
        }
    }

    private func stopMeeting() {
        guard !meetingFinishing else { return }
        meetingFinishing = true; meetingAttemptID = nil
        meetingStarting = false
        mainWC.settings.meetingCapturing = false
        dockController.state.meetingRecording = false   // clear the red indicator immediately
        dockController.state.meetingMicTrouble = false // ...and never start the next meeting amber
        overlay.show(.message("Finishing recording…"))
        Task {
            let wav = await meetingRecorder.stop()
            await MainActor.run {
                self.meetingFinishing = false
                self.mainWC.settings.activeJournal = nil
                self.recorder.resumeAfterMeeting(); self.refreshDockMic(); self.recordingsChanged()
            }
            guard wav.count > 8_000 else {
                await MainActor.run {
                    self.overlay.show(.message("No meeting audio captured — check Screen Recording permission"))
                    self.overlay.hide(after: 4)
                }
                return
            }
            let stamp = Self.meetingStamp.string(from: Date())
            // Save the raw recording to a proper app folder FIRST, so processing
            // can never lose it (re-runnable via "Summarize a recording…"). A
            // 44-min meeting was lost once before this safeguard. Not the Desktop.
            let wavURL = meetingRecorder.savedRecordingURL ?? Self.recordingsDir().appendingPathComponent("meeting-\(UUID().uuidString).wav")
            var saved = meetingRecorder.savedRecordingURL != nil
            if !saved {
                do { try RecordingStore.durableWrite(wav, to: wavURL); saved = true }
                catch { await MainActor.run { self.mainWC.settings.status = "Recording save failed: \(error.localizedDescription)" } }
            }
            do {
                // Submit for ASYNC processing — the durable server job survives even
                // if this app quits; the result appears in the Meetings window.
                let id = try await client.submitMeeting(wav: wav, title: "Meeting \(stamp)")
                vlog("meeting submitted: job \(id)")
                await MainActor.run { self.overlay.hide(); self.mainWC.show(client: self.client, section: .meetings) }
            } catch {
                vlog("meeting submit FAILED: \(error)")
                await MainActor.run {
                    self.overlay.show(.message("\(saved ? "Recording saved. Retry via Summarize a recording." : "Recording could not be saved.") Upload failed: \(error.localizedDescription)"))
                    self.overlay.hide(after: 6)
                }
            }
        }
    }

    private static let meetingStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"; return f
    }()

    /// The proper home for raw meeting recordings — an app folder under
    /// Application Support, NOT the Desktop. Created on demand.
    static func recordingsDir() -> URL {
        let dir = RecordingStore.recordingsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func pendingDir() -> URL {
        let dir = RecordingStore.pendingDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write notes next to the recording; fall back to the recordings folder if
    /// that folder isn't writable.
    private func saveMeetingNotes(_ md: String, base: String, near url: URL) throws -> URL {
        let name = "\(base) — notes.md"
        let sibling = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try md.data(using: .utf8)!.write(to: sibling)
            return sibling
        } catch {
            let fallback = Self.recordingsDir().appendingPathComponent(name)
            try md.data(using: .utf8)!.write(to: fallback)
            return fallback
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
        mainWC.settings.selectMic(uid)
        // reloadDevice is notified centrally   // apply immediately (rebuilds the warm engine)
        vlog("mic switched via menu -> \(uid.isEmpty ? "system default" : uid)")
        overlay.show(.message("Microphone: \(sender.title)"))
        overlay.hide(after: 1.5)
        refreshDockMic()
    }

    /// Reflect the mic actually in use on the dock — the LIVE default device name
    /// (e.g. "PowerConf"), not a generic "System default", so you always see which
    /// mic is active. Updated at launch, periodically, and at each recording.
    private func refreshDockMic() {
        let active = meetingRecorder.isRecording ? meetingRecorder.micName : recorder.isEngineRunning ? recorder.lastWinningMic : nil
        let requested = AudioDevices.preferredInput()?.name ?? "No permitted input"
        dockController.state.micName = active ?? "Requested: \(requested)"
        mainWC.settings.activeMicName = active ?? "Idle · requested \(requested)"
    }

    private var previewWindow: NSWindow?
    /// Renders DockView in its states for screenshot verification (VF_DOCK_PREVIEW=1).
    private func showDockPreview() {
        let idle = DockState(); idle.serverOK = true
        let listening = DockState(); listening.begin(); listening.elapsed = 8
        // A real speech envelope so the preview shows the waveform as it actually
        // behaves — travelling, with the accent on the peak.
        for v in [0.05, 0.08, 0.15, 0.3, 0.55, 0.8, 0.95, 0.7, 0.5, 0.62, 0.85, 0.6,
                  0.35, 0.2, 0.28, 0.45, 0.7, 0.55, 0.3, 0.18, 0.1, 0.06, 0.04, 0.03] as [Float] {
            listening.setLevel(v)
        }
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
        // Every state the human actually sees — a review that only looks at three
        // of them cannot judge whether the app feels continuous.
        let transcribing = DockState(); transcribing.begin(); transcribing.finishRecording()
        let failed = DockState(); failed.fail("No audio. Check that your mic is not muted.")
        let recording = DockState(); recording.serverOK = true; recording.meetingRecording = true
        let offer = DockState(); offer.serverOK = true
        offer.callTitle = CallSource.offerTitle(for: "Microsoft Teams ModuleHost")
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains("teams")
        }), let icon = app.icon, let tiff = icon.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            offer.callIconPNG = rep.representation(using: .png, properties: [:])
        }
        offer.callOffer = true

        let root = VStack(alignment: .leading, spacing: 22) {
            row("AT REST", mk(idle, false))
            row("RECORDING", mk(recording, false))
            row("CALL OFFER", mk(offer, false))
            row("LISTENING", mk(listening, false))
            row("TRANSCRIBING", mk(transcribing, false))
            row("ERROR", mk(failed, false))
            row("EXPANDED", mk(controls, true))
        }
        .padding(44)
        .frame(width: 620)
        .background(Color(red: 0.93, green: 0.92, blue: 0.90))
        let host = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: host)
        w.title = "Dock Preview"
        w.styleMask = [.titled, .closable, .resizable]
        w.setContentSize(NSSize(width: 700, height: 700))
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

    @objc private func focusRecordingControls() { dockController.focusControls() }

    private func wireClientExperience() {
        let settings = mainWC.settings
        dockController.onRecovery = { [weak self] in
            guard let self = self else { return }; self.mainWC.show(client: self.client, section: .inbox)
        }
        settings.onCheckPermissions = { [weak self] in self?.refreshPermissions() }
        settings.onRequestMicrophone = { [weak self] in self?.requestMicPermission() }
        settings.onRequestAccessibility = { [weak self] in self?.ensureAccessibilityPrompt() }
        settings.onRequestScreen = { [weak self] in
            _ = CGRequestScreenCaptureAccess()
            self?.refreshPermissions()
        }
        settings.captureMode = dockController.state.mode
        settings.onModeChanged = { [weak self] mode in self?.dockController.state.mode = mode }
        settings.onToggleRecording = { [weak self] in self?.toggleRecording(trigger: "capture-page") }
        settings.onToggleMeeting = { [weak self] in self?.toggleMeeting() }
        settings.onImportRecording = { [weak self] in self?.summarizeRecording() }
        settings.onCancelImport = { [weak self] in self?.importTask?.cancel() }
        settings.onRetryRecording = { [weak self] id in self?.retryRecording(id) }
        settings.onConfirmPlacement = { [weak self] id in
            guard let self = self, var entry = try? RecordingStore.entries().first(where: { $0.id == id }), entry.sentUnverified else { return }
            do {
                entry.status = "inserted"; entry.error = ""; try RecordingStore.save(entry)
                try RecordingStore.removeAudio(id); self.recordingsChanged()
            } catch { settings.status = "Could not confirm placement: \(error.localizedDescription)" }
        }
        settings.onReviewRecording = { [weak self] id in self?.reviewRecording(id) }
        settings.onCancelRecording = { [weak self] id in self?.processingTasks[id]?.cancel() }
        settings.onDiscardRecording = { [weak self] id in
            guard let self = self else { return }
            guard self.processingTasks[id] == nil else { settings.status = "Cancel processing before removing this recording."; return }
            do {
                try RecordingStore.discard(id)
                self.unsavedRecordings[id] = nil
                if self.reviewedRecordingID == id { self.promptReview.discardOpenReview(); self.reviewedRecordingID = nil }
                self.destinations[id] = nil; self.remotePreparations.removeValue(forKey: id)?.cancel()
                settings.status = "Recording removed from this Mac"; self.recordingsChanged()
            } catch { settings.status = "Could not remove recording: \(error.localizedDescription)" }
        }
        recorder.onDeviceChanged = { [weak self] _ in self?.refreshDockMic() }
        recorder.onCaptureFailure = { [weak self] message in
            guard let self = self, self.isRecording else { return }
            if let id = self.activeRecordingID { self.destinations.removeValue(forKey: id) }
            self.endRecording()
            self.mainWC.settings.status = "Microphone interrupted: \(message). Any captured audio is retained in Inbox."
        }
        meetingRecorder.onCaptureFailure = { [weak self] message in
            guard let self = self else { return }
            self.mainWC.settings.status = message
            self.dockController.state.fail(message)
            if self.meetingRecorder.isRecording { self.stopMeeting() }
        }
        NotificationCenter.default.addObserver(forName: .vfInputPolicyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.recorder.reloadDevice(); self?.refreshDockMic()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPermissions()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let target = CaptureDestination.capture() { self?.lastExternalDestination = target }
            }
        }
        do { try RecordingStore.recoverInterruptedProcessing() }
        catch { settings.status = "Could not recover interrupted processing: \(error.localizedDescription)" }
        refreshPermissions(); settings.reloadRecovery()
    }

    private func refreshPermissions() {
        let settings = mainWC.settings
        settings.microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "Allowed" : "Permission needed"
        settings.accessibilityPermission = AXIsProcessTrusted() ? "Allowed" : "Permission needed"
        settings.screenPermission = CGPreflightScreenCaptureAccess() ? "Allowed" : "Needed for meetings"
        if AXIsProcessTrusted() {
            if globalMonitor == nil { setupHotkey() }
            if eventTap == nil { setupMouseTap() }
        }
        if ProcessInfo.processInfo.environment["VF_VALIDATION"] == "1",
           let directory = ProcessInfo.processInfo.environment["VF_DATA_DIR"] {
            let snapshot: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                "server": client.baseURL.absoluteString, "recordings": RecordingStore.recordingsDirectory().path,
                "microphone": settings.microphonePermission, "accessibility": settings.accessibilityPermission,
                "screenRecording": settings.screenPermission, "globalShortcut": globalMonitor != nil,
                "localShortcut": localMonitor != nil, "mouseTap": eventTap != nil,
                "inputActive": recorder.isEngineRunning]
            let path = URL(fileURLWithPath: directory).appendingPathComponent("review-status.json")
            if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) {
                try? data.write(to: path, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }
        }
    }

    // MARK: - Permissions

    private func requestMicPermission() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.refreshPermissions()
                self?.mainWC.settings.status = granted ? "Microphone allowed. Start recording when ready." : "Allow Microphone in System Settings to record."
            }
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
                self.beginRecording(prompt: self.dockController.state.mode == .prompt, trigger: "right-option")
            } else {
                self.endRecording()
            }
        }
        let isolated = ProcessInfo.processInfo.environment["VF_VALIDATION"] == "1"
        let validateHotkeys = ProcessInfo.processInfo.environment["VF_VALIDATE_HOTKEYS"] == "1"
        guard !isolated || validateHotkeys else {
            vlog("validation: local/global recording shortcuts disabled")
            return
        }
        if globalMonitor == nil && (!isolated || validateHotkeys) { globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: handler) }
        if localMonitor == nil { localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in handler(event); return event } }

        setupMouseTap()
        vlog("hotkey monitors installed (global=\(globalMonitor != nil)) mouseToggleButton=\(mouseToggleButton)")
    }

    /// CGEventTap for mouse-button toggle — can CONSUME the click so the button's
    /// native action (middle-click paste, side-button back/forward) doesn't fire.
    private func setupMouseTap() {
        if ProcessInfo.processInfo.environment["VF_VALIDATION"] == "1" && ProcessInfo.processInfo.environment["VF_VALIDATE_HOTKEYS"] != "1" { return }
        guard eventTap == nil, AXIsProcessTrusted() else { return }
        let mask = (UInt64(1) << CGEventType.otherMouseDown.rawValue) | (UInt64(1) << CGEventType.keyDown.rawValue)
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
        if type == .keyDown, capturingMouseTrigger, event.getIntegerValueField(.keyboardEventKeycode) == 53 { cancelMouseLearning(); return nil }
        guard type == .otherMouseDown else { return Unmanaged.passUnretained(event) }
        let btn = Int(event.getIntegerValueField(.mouseEventButtonNumber))

        if capturingMouseTrigger {
            cancelMouseLearning()
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

    private func toggleRecording(trigger: String = "mouse-button") {
        // Debounce so one physical click = one toggle (no desync from double-fire).
        let now = Date()
        if now.timeIntervalSince(lastToggle) < 0.25 { return }
        lastToggle = now
        if isRecording { endRecording() } else { beginRecording(prompt: dockController.state.mode == .prompt, trigger: trigger) }
    }

    @objc private func setMouseTrigger() {
        capturingMouseTrigger = true
        mouseLearningTimer?.invalidate()
        mouseLearningTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.cancelMouseLearning()
        }
        overlay.show(.message("Click the mouse button you want to use as your dictation trigger…"))
        overlay.hide(after: 6)
    }

    private func cancelMouseLearning() {
        capturingMouseTrigger = false; mouseLearningTimer?.invalidate(); mouseLearningTimer = nil
        overlay.hide()
    }

    @objc private func clearMouseTrigger() {
        cancelMouseLearning()
        mouseToggleButton = -1
        setupMenu()
        overlay.show(.message("Mouse trigger cleared"))
        overlay.hide(after: 1.5)
    }

    // MARK: - Record → transcribe → insert

    private var remotePreparations: [UUID: Task<Void, Error>] = [:]
    private var remoteDestinationNames: [UUID: String] = [:]

    private func beginRecording(prompt: Bool = false, trigger: String = "menu-test") {
        guard !terminationPending, !isRecording, !meetingStarting, !meetingFinishing, !meetingRecorder.isRecording else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { requestMicPermission(); return }
        let intentAt = ProcessInfo.processInfo.systemUptime
        let id = UUID()
        vlog("capture begin: pid=\(ProcessInfo.processInfo.processIdentifier), id=\(id), source=\(Bundle.main.bundleIdentifier ?? "unbundled")")
        activeRecordingID = id; presentationID = id
        captureDestination = CaptureDestination.capture { vlog("capture destination: id=\(id) trigger=\(trigger) \($0)") }
        if let target = captureDestination {
            destinations[id] = target
            if target.isRemote {
                remotePreparations[id] = Task { @MainActor in try await self.prepareRemote(target, id: id) }
            }
        }
        vlog("capture timing: id=\(id) destinationMs=\(Int((ProcessInfo.processInfo.systemUptime - intentAt) * 1000))")
        isRecording = true; promptMode = prompt
        mainWC.settings.capturing = true
        dockController.state.starting()
        mainWC.settings.captureStatus = "Starting microphone…"
        recorder.onLevel = { [weak self] level in self?.dockController.state.setLevel(level) }
        recorder.start { [weak self] ok in
            guard let self = self, self.activeRecordingID == id, self.isRecording else { return }
            vlog("capture startup completed: id=\(id), ready=\(ok), pressToReadyMs=\(Int((ProcessInfo.processInfo.systemUptime - intentAt) * 1000))")
            if ok {
                self.dockController.state.begin()
                self.mainWC.settings.captureStatus = "Listening"
                self.mainWC.settings.capturing = true
                self.refreshDockMic(); SoundFeedback.listening()
            } else {
                self.isRecording = false
                self.mainWC.settings.capturing = false
                self.mainWC.settings.captureStatus = "Microphone unavailable. Check readiness."
                self.dockController.state.fail("Microphone unavailable · open Microphone settings")
            }
        }
    }

    private func endRecording() {
        guard isRecording, let id = activeRecordingID else { return }
        isRecording = false; activeRecordingID = nil
        mainWC.settings.capturing = false
        recordingStoppedAt[id] = ProcessInfo.processInfo.systemUptime
        let wav = recorder.stop()
        dockController.state.finishRecording()
        guard wav.count > 8_000 else {
            recordingStoppedAt.removeValue(forKey: id)
            let message = wav.count <= 64 ? "No audio captured. Wait for Listening, then speak." : "Recording too short. Hold the trigger while speaking."
            dockController.state.fail(message); mainWC.settings.captureStatus = message
            SoundFeedback.failed(); return
        }
        do {
            _ = try RecordingStore.create(wav: wav, kind: promptMode ? "prompt" : "dictation", id: id)
            recordingsChanged()
            enqueueRecording(id)
        } catch {
            var entry = RecordingStore.Entry(id: id, kind: promptMode ? "prompt" : "dictation")
            entry.error = "Audio is held in memory. Free disk space, then Retry. Keep WhisperType open."
            unsavedRecordings[id] = (wav, entry); recordingsChanged()
            dockController.state.fail(entry.error)
            mainWC.settings.captureStatus = "Could not save audio: \(error.localizedDescription)"
        }
    }

    private func recordingsChanged() {
        mainWC.settings.unsavedRecordings = unsavedRecordings.values.map(\.entry)
        mainWC.settings.reloadRecovery()
        NotificationCenter.default.post(name: .vfRecordingsChanged, object: nil)
    }

    private func retryRecording(_ id: UUID) {
        if let unsaved = unsavedRecordings[id] {
            do {
                let directory = RecordingStore.pendingDirectory()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try RecordingStore.durableWrite(unsaved.audio, to: RecordingStore.audioURL(id))
                try RecordingStore.save(unsaved.entry)
                unsavedRecordings[id] = nil; recordingsChanged()
            } catch { mainWC.settings.status = "Audio still held in memory: \(error.localizedDescription)"; return }
        }
        enqueueRecording(id)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isRecording || meetingStarting || meetingFinishing || meetingRecorder.isStarting || meetingRecorder.isRecording {
            let alert = NSAlert()
            alert.messageText = "Finish recording before quitting"
            alert.informativeText = "Stop the current recording so WhisperType can save it."
            alert.addButton(withTitle: "Keep recording")
            alert.runModal()
            return .terminateCancel
        }
        if !processingTasks.isEmpty {
            guard !terminationPending else { return .terminateLater }
            terminationPending = true
            mainWC.settings.captureStatus = "Finishing saved dictation before quitting…"
            Task { @MainActor in
                while !self.processingTasks.isEmpty {
                    let tasks = Array(self.processingTasks.values)
                    for task in tasks { await task.value }
                }
                self.terminationPending = false
                sender.reply(toApplicationShouldTerminate: self.applicationShouldTerminate(sender) == .terminateNow)
            }
            return .terminateLater
        }
        guard promptReview.prepareToQuit() else { return .terminateCancel }
        guard !unsavedRecordings.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Some recordings could not be saved"
        alert.informativeText = "Keep WhisperType open, free disk space, and retry in Inbox. Quitting now discards the audio held in memory."
        alert.addButton(withTitle: "Keep open"); alert.addButton(withTitle: "Quit and discard")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    private func enqueueRecording(_ id: UUID) {
        guard !terminationPending, processingTasks[id] == nil else { return }
        let previous = processingTail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self = self else { return }
            defer { self.processingTasks.removeValue(forKey: id) }
            guard !Task.isCancelled else { return }
            await self.processRecording(id)
        }
        processingTasks[id] = task; processingTail = task
    }

    @MainActor private func processRecording(_ id: UUID) async {
        let processingAt = ProcessInfo.processInfo.systemUptime
        if let stopped = recordingStoppedAt[id] { vlog("pipeline timing: id=\(id) stopToProcessingMs=\(Int((processingAt - stopped) * 1000))") }
        defer {
            if let stopped = recordingStoppedAt.removeValue(forKey: id) { vlog("pipeline timing: id=\(id) stopToResultMs=\(Int((ProcessInfo.processInfo.systemUptime - stopped) * 1000))") }
        }
        guard var entry = try? RecordingStore.entries().first(where: { $0.id == id }) else { return }
        do {
            entry.status = "processing"; entry.error = ""; try RecordingStore.save(entry); recordingsChanged()
            let wav = try Data(contentsOf: RecordingStore.audioURL(id), options: .mappedIfSafe)
            guard !AudioRecorder.isAllZero(Data(wav.dropFirst(44))) else {
                throw NSError(domain: "whispertype.capture", code: 2, userInfo: [NSLocalizedDescriptionKey: "No microphone signal was captured. Your audio is saved; check the selected input before recording again."])
            }
            if entry.kind == "prompt" {
                let result = try await client.engineer(wav: wav)
                try Task.checkCancellation()
                entry.raw = result.raw
                entry.variants = ["concise": result.concise, "detailed": result.detailed, "coding": result.coding]
                entry.text = result.concise
                guard entry.hasResult else { throw emptyTranscriptionError() }
                entry.status = "ready"
                try RecordingStore.save(entry); recordingsChanged()
                if presentationID == id && !isRecording && !promptReview.isVisible { reviewRecording(id) }
                else if presentationID == id && !isRecording { dockController.state.ready() }
            } else {
                let requestAt = ProcessInfo.processInfo.systemUptime
                let result = try await client.transcribe(wav: wav)
                vlog("pipeline timing: id=\(id) asrRequestMs=\(Int((ProcessInfo.processInfo.systemUptime - requestAt) * 1000))")
                try Task.checkCancellation()
                entry.raw = result.raw; entry.text = result.text; entry.historyID = result.id
                // Remote preparation captures the actual destination app. An
                // unavailable app identity leaves the server result untouched.
                if let target = destinations[id] {
                    if target.isRemote { _ = try? await remotePreparations[id]?.value }
                    entry.text = SpokenListFormatter.format(result.text, destinationName: target.isRemote ? remoteDestinationNames[id] : target.name)
                }
                guard entry.hasResult else { throw emptyTranscriptionError() }
                entry.status = "ready"
                try RecordingStore.save(entry); recordingsChanged()
                addToHistory(entry.text); lastDictationId = result.id; lastDictationText = entry.text
                if destinations[id] == nil { vlog("insertion deferred: id=\(id) no-captured-destination") }
                if isRecording { vlog("insertion deferred: id=\(id) another-recording-active") }
                if !isRecording, let target = destinations[id], target.isCurrent(diagnose: { vlog("insertion destination: id=\(id) \($0)") }) {
                    try await insert(entry.text, into: target, id: id)
                    entry.status = "inserted"; try RecordingStore.save(entry)
                    try RecordingStore.removeAudio(id)
                    if presentationID == id {
                        dockController.state.complete(words: entry.text.split(whereSeparator: { $0.isWhitespace }).count)
                        mainWC.settings.captureStatus = "Sent to \(target.name)"; SoundFeedback.done()
                    }
                } else {
                    entry.error = "Result ready. Review it in Inbox to choose placement."
                    try RecordingStore.save(entry)
                    if presentationID == id && !isRecording { dockController.state.ready(); mainWC.settings.captureStatus = "Result ready in Inbox" }
                }
            }
        } catch {
            entry.status = (error as NSError).domain == "whispertype.insertion" && (error as NSError).code == 2 ? "sent_unverified" : entry.hasResult ? "ready" : "pending"
            entry.sendCompleted = entry.status == "sent_unverified" ? true : entry.sendCompleted
            entry.error = error is CancellationError ? "Processing canceled. Audio retained; retry when ready." : error.localizedDescription
            do { try RecordingStore.save(entry) } catch { mainWC.settings.status = "Could not update recovery metadata: \(error.localizedDescription)" }
            if presentationID == id && !isRecording {
                if entry.sentUnverified { dockController.state.sentUnverified(); mainWC.settings.captureStatus = "Sent" }
                else { dockController.state.fail("\(entry.error) · open Inbox") }
            }
        }
        recordingsChanged()
    }

    private func emptyTranscriptionError() -> NSError {
        NSError(domain: "whispertype.capture", code: 3, userInfo: [NSLocalizedDescriptionKey: "No transcript was returned. Your audio is saved; check the microphone before recording again."])
    }

    private func reviewRecording(_ id: UUID) {
        guard let entry = try? RecordingStore.entries().first(where: { $0.id == id }) else { return }
        if entry.sentUnverified {
            let alert = NSAlert(); alert.messageText = "Text may already be in place"
            alert.informativeText = "Check the destination first. Opening this review does not send anything; choosing Insert again may create a duplicate."
            alert.addButton(withTitle: "Review sent text"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        reviewedRecordingID = id
        let target = lastExternalDestination ?? destinations[id]
        let chosen: (String?) -> Void = { [weak self] text in
            guard let self = self, let text = text, !text.isEmpty else { return }
            guard var edited = try? RecordingStore.entries().first(where: { $0.id == id }) else { return }
            edited.text = text; edited.status = "ready"; edited.sendCompleted = false; edited.error = ""
            do { try RecordingStore.save(edited) }
            catch { self.mainWC.settings.status = "Could not save edit: \(error.localizedDescription)"; return }
            guard let target = target else {
                self.mainWC.settings.status = "Choose a destination app, then return to Inbox. Your edited result is saved."
                self.recordingsChanged(); return
            }
            target.app.activate(options: [])
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                do {
                    let attemptID = UUID() // Explicit review is a new placement, never an automatic replay.
                    if target.isRemote { try await self.prepareRemote(target, id: attemptID) }
                    try await self.insert(text, into: target, id: attemptID)
                    edited.status = "inserted"; edited.error = ""
                    try RecordingStore.save(edited); try RecordingStore.removeAudio(id)
                    self.dockController.state.complete(words: text.split(whereSeparator: { $0.isWhitespace }).count)
                } catch {
                    edited.error = error.localizedDescription
                    if (error as NSError).domain == "whispertype.insertion", (error as NSError).code == 2 { edited.status = "sent_unverified"; edited.sendCompleted = true }
                    try? RecordingStore.save(edited)
                    if edited.sentUnverified { self.dockController.state.sentUnverified() }
                    else { self.dockController.state.fail("Result retained in Inbox: \(error.localizedDescription)") }
                }
                self.recordingsChanged()
            }
        }
        let destination = target.map { "\($0.name) · \($0.title)" } ?? "Choose a destination app, then return to Inbox"
        let saveDraft: ([String: String], String) throws -> Void = { [weak self] variants, text in
            guard var draft = try RecordingStore.entries().first(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
            if draft.text != text || draft.variants != variants {
                draft.status = "ready"; draft.sendCompleted = false
                draft.error = "Edited result saved. Review it to choose placement."
            }
            draft.text = text; draft.variants = variants
            try RecordingStore.save(draft); self?.recordingsChanged()
        }
        if !entry.variants.isEmpty {
            promptReview.show(concise: entry.variants["concise"] ?? entry.text,
                              detailed: entry.variants["detailed"] ?? "", coding: entry.variants["coding"] ?? "", destination: destination, onDraft: saveDraft, onChoose: chosen)
        } else { promptReview.showText(entry.text, destination: destination, onDraft: saveDraft, onChoose: chosen) }
    }

    @MainActor private func insert(_ text: String, into target: CaptureDestination, id: UUID) async throws {
        guard target.isCurrent() else { throw insertionError("Destination changed. Result retained; review placement.") }
        if target.isRemote {
            defer { remotePreparations[id] = nil; remoteDestinationNames[id] = nil }
            try await remotePreparations[id]?.value
            guard target.isCurrent(), !isRecording else { throw insertionError("Destination changed. Review placement in Inbox.") }
            let receipt = try await remoteRequest(path: "insert", target: target, id: id, text: text)
            guard receipt["verified"] as? Bool == true else {
                throw insertionError("Keys were sent; the destination could not confirm the text. Inspect it before inserting again. Audio and result remain in Inbox.", code: 2)
            }
        } else {
            guard AXIsProcessTrusted() else { throw insertionError("Allow Accessibility to type into the destination.") }
            let before = target.readableValue()
            let expected = target.expectedValue(afterInserting: text)
            let typingAt = ProcessInfo.processInfo.systemUptime
            let complete = await NativePasteInserter.paste(text, targetPID: target.app.processIdentifier, isCurrent: { target.isCurrent() })
            guard complete else { throw insertionError("Paste was not sent. Check the destination; your result is retained.") }
            vlog("pipeline timing: id=\(id) typingMs=\(Int((ProcessInfo.processInfo.systemUptime - typingAt) * 1000)) utf16=\(text.utf16.count)")
            // Without a readable baseline/selection an exact receipt cannot
            // become valid by waiting. Report sent-unverified immediately.
            if expected != nil {
                for attempt in 0...5 {
                    if target.containsVerifiedValue(expected) { vlog("insertion receipt: id=\(id) verified"); return }
                    if attempt < 5 { try await Task.sleep(nanoseconds: 100_000_000) }
                }
            }
            if expected != nil, let before, target.isCurrent(), target.readableValue() == before {
                throw insertionError("The destination did not accept the paste. Your result is retained in Inbox.")
            }
            vlog("insertion receipt: id=\(id) unverified " + target.receiptDiagnostic(expected))
            throw insertionError("Paste was sent; the destination does not expose a text receipt. Audio and result remain in History.", code: 2)
        }
    }

    private func insertionError(_ message: String, code: Int = 1) -> NSError {
        NSError(domain: "whispertype.insertion", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @MainActor private func prepareRemote(_ target: CaptureDestination, id: UUID) async throws {
        guard target.isCurrent() else { throw insertionError("Remote destination changed before capture.") }
        let response = try await remoteRequest(path: "prepare", target: target, id: id)
        remoteDestinationNames[id] = response["application"] as? String
    }

    private func remoteRequest(path: String, target: CaptureDestination, id: UUID, text: String? = nil) async throws -> [String: Any] {
        let env = ProcessInfo.processInfo.environment
        let pairingURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperType/RemotePairing.json")
        let pairing = (try? JSONDecoder().decode([String:String].self, from: Data(contentsOf: pairingURL))) ?? [:]
        let match = env["VF_REMOTE_WINDOW_MATCH"] ?? pairing["VF_REMOTE_WINDOW_MATCH"] ?? ""
        guard !match.isEmpty, target.title.localizedCaseInsensitiveContains(match),
              let address = env["VF_REMOTE_AGENT_URL"] ?? pairing["VF_REMOTE_AGENT_URL"], let base = URL(string: address),
              ["http", "https"].contains(base.scheme ?? ""), base.host != nil else {
            throw insertionError("Pair the remote agent and identify its Screen Sharing window before insertion.")
        }
        let key = env["VF_REMOTE_AGENT_KEY"] ?? pairing["VF_REMOTE_AGENT_KEY"] ?? ""
        guard key.utf8.count >= 32 else { throw insertionError("Remote pairing needs a key of at least 32 bytes.") }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"; request.timeoutInterval = path == "insert" ? 120 : 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["id": id.uuidString]
        if let text = text { body["text"] = text }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw insertionError(object?["detail"] as? String ?? "Remote insertion could not be confirmed. Inspect the paired Mac before retrying.")
        }
        guard let object = object, object["id"] as? String == id.uuidString,
              object["status"] as? String == (path == "prepare" ? "prepared" : "posted") else {
            throw insertionError("Remote agent returned an invalid receipt. Inspect the destination before retrying.")
        }
        return object
    }
}

// A Finder relaunch of the disposable Review bundle must not fall back to
// production defaults. Ordinary signed production bundles never load this file.
if Bundle.main.bundleIdentifier?.hasSuffix(".review.client") == true {
    do {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "VFReviewEnvironmentFile") as? String else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let values = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let expectedData = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WhisperType Review Validation").path
        guard values["VF_VALIDATION"] == "1", values["VF_SERVER_URL"] == "http://127.0.0.1:18790",
              values["VF_DATA_DIR"] == expectedData else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for (key, value) in values where key.hasPrefix("VF_") { setenv(key, value, 1) }
    } catch {
        fputs("Review configuration unavailable; refusing to start with production defaults.\n", stderr)
        exit(1)
    }
}
// Explicit destination support command: no controller, microphone, keys, windows,
// server requests or preference writes. May request the target app accessibility
// tree, as ordinary capture does. Launch in the background to preserve focus.
if CommandLine.arguments.contains("--diagnose-destination") {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let identity = "destination-check pid=\(ProcessInfo.processInfo.processIdentifier)"
    vlog("\(identity) trusted=\(AXIsProcessTrusted())")
    let target = CaptureDestination.capture { vlog("\(identity) \($0)") }
    vlog("\(identity) editable-target=\(target != nil)")
    if CommandLine.arguments.contains("--inspect-receipt-shape"), let target = target, !target.isRemote {
        vlog("\(identity) receipt-shape \(target.receiptShapeDiagnostic())")
    }
    if CommandLine.arguments.contains("--profile-focus"), let target = target {
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            let old = target.isCurrentByRecapturing()
            let middle = ProcessInfo.processInfo.systemUptime
            let fast = target.isCurrent()
            let end = ProcessInfo.processInfo.systemUptime
            vlog("\(identity) focus-profile recaptureMs=\(Int((middle-start)*1000)) identityMs=\(Int((end-middle)*1000)) recaptureCurrent=\(old) identityCurrent=\(fast)")
        }
    }
    if CommandLine.arguments.contains("--save-remote-window-match") {
        guard let target = target, target.isRemote, !target.title.isEmpty else { exit(2) }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WhisperType")
        let file = directory.appendingPathComponent("RemotePairing.json")
        do {
            var pairing = (try? JSONDecoder().decode([String:String].self, from: Data(contentsOf:file))) ?? [:]
            let suffix = " – Locked"
            pairing["VF_REMOTE_WINDOW_MATCH"] = target.title.hasSuffix(suffix) ? String(target.title.dropLast(suffix.count)) : target.title
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try JSONEncoder().encode(pairing).write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            vlog("\(identity) remote-window-match-saved")
        } catch { exit(3) }
    }
    if CommandLine.arguments.contains("--inspect-focus-tree") { CaptureDestination.diagnoseFocusedTree { vlog("\(identity) \($0)") } }
    exit(target == nil ? 1 : 0)
}
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
