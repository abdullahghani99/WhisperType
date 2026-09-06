import SwiftUI
import AppKit
import WhisperTypeKit

extension Notification.Name {
    /// Posted when the pre-roll toggle changes so the recorder can start/stop
    /// its always-warm engine live (no relaunch).
    static let vfInputPolicyChanged = Notification.Name("vfInputPolicyChanged")
    static let vfRecordingsChanged = Notification.Name("vfRecordingsChanged")
    static let vfPrerollChanged = Notification.Name("vfPrerollChanged")
}

/// Backing state for the settings window: talks to the server's /vocab and
/// /history endpoints. @Published writes are marshalled to the main thread.
final class SettingsState: ObservableObject {
    @Published var replacements: [(String, String)] = []
    @Published var terms: [String] = []
    @Published var snippets: [(String, String)] = []
    @Published var history: [String] = []
    @Published var status: String = ""
    @Published var micDevices: [AudioInputDevice] = []
    @Published var suggestions: [ServerClient.Suggestion] = []
    @Published var serverOK: Bool = false
    @Published var selectedMicUID: String = UserDefaults.standard.string(forKey: AudioDevices.defaultsKey) ?? ""
    @Published var prerollEnabled: Bool = (UserDefaults.standard.object(forKey: "vf_preroll") as? Bool ?? true) {
        didSet {
            guard prerollEnabled != oldValue else { return }
            UserDefaults.standard.set(prerollEnabled, forKey: "vf_preroll")
            NotificationCenter.default.post(name: .vfPrerollChanged, object: nil)
        }
    }

    @Published var captureStatus = "Ready when you are"
    @Published var captureMode: DockState.Mode = .dictation {
        didSet { if captureMode != oldValue { onModeChanged?(captureMode) } }
    }
    var onModeChanged: ((DockState.Mode) -> Void)?
    @Published var capturing = false
    @Published var meetingCapturing = false
    var onToggleRecording: (() -> Void)?
    var onToggleMeeting: (() -> Void)?
    var onImportRecording: (() -> Void)?
    var onCancelImport: (() -> Void)?
    @Published var importing = false
    @Published var importStatus = ""
    @Published var activeMicName = "Microphone idle"
    @Published var microphonePermission = "Not checked"
    @Published var accessibilityPermission = "Not checked"
    @Published var screenPermission = "Not checked"
    @Published var historyItems: [ServerClient.HistoryItem] = []
    @Published var recoveryEntries: [RecordingStore.Entry] = []
    @Published var interruptedMeetings: [URL] = []
    @Published var undoSuggestionID: Int?
    @Published var removedVocab: (kind: String, key: String, value: String)?
    @Published var bluetoothWarm = AudioDevices.warmBluetooth {
        didSet { UserDefaults.standard.set(bluetoothWarm, forKey: "vf_bluetoothWarm"); policyChanged() }
    }
    @Published var allowBluetooth = UserDefaults.standard.object(forKey: "vf_allowBluetoothInput") as? Bool ?? true {
        didSet { UserDefaults.standard.set(allowBluetooth, forKey: "vf_allowBluetoothInput"); policyChanged() }
    }
    var onCheckPermissions: (() -> Void)?
    var onRequestMicrophone: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onRequestScreen: (() -> Void)?
    var onRetryRecording: ((UUID) -> Void)?
    var onReviewRecording: ((UUID) -> Void)?
    var onCancelRecording: ((UUID) -> Void)?
    var onDiscardRecording: ((UUID) -> Void)?
    var unsavedRecordings: [RecordingStore.Entry] = []
    var activeJournal: URL?

    private func policyChanged() {
        NotificationCenter.default.post(name: .vfInputPolicyChanged, object: nil)
    }
    func reloadRecovery() {
        do {
            let saved = try RecordingStore.entries().filter { $0.status != "inserted" }
            let unsavedIDs = Set(unsavedRecordings.map(\.id))
            recoveryEntries = (unsavedRecordings + saved.filter { !unsavedIDs.contains($0.id) }).sorted { $0.created > $1.created }
            let root = RecordingStore.recordingsDirectory()
            interruptedMeetings = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasPrefix("capture-") && $0 != activeJournal } ?? []
        } catch { status = error.localizedDescription }
    }
    func recoverMeeting(_ directory: URL) {
        do {
            let destination = RecordingStore.recordingsDirectory().appendingPathComponent("recovered-\(UUID().uuidString).wav")
            try MeetingAudioJournal.recover(directory: directory, to: destination)
            status = "Recovered recording. Use Summarize a recording to process it."
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { status = "Recovery failed: \(error.localizedDescription)" }
    }
    func removeVocab(kind: String, key: String, value: String) {
        guard let client = client else { return }
        Task {
            do {
                try await client.removeVocab(kind: kind, key: key, value: value)
                await MainActor.run { self.removedVocab = (kind, key, value); self.status = "Removed \(key)"; self.reload() }
            } catch { await MainActor.run { self.status = error.localizedDescription } }
        }
    }
    func discardRecording(_ id: UUID) {
        if let onDiscardRecording = onDiscardRecording { onDiscardRecording(id); return }
        do { try RecordingStore.discard(id); status = "Recording removed from this Mac"; reloadRecovery() }
        catch { status = "Could not remove recording: \(error.localizedDescription)" }
    }
    func deleteHistory(_ id: Int) {
        guard let client = client else { return }
        Task {
            do {
                try await client.deleteHistory(id: id)
                await MainActor.run { self.historyItems.removeAll { $0.id == id }; self.status = "Removed from server history" }
            } catch { await MainActor.run { self.status = error.localizedDescription } }
        }
    }
    func addSnippet(_ trigger: String, _ expansion: String, onSuccess: @escaping () -> Void) {
        let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let client = client, !trigger.isEmpty, !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            do {
                try await client.addVocab(snippets: [trigger: expansion])
                await MainActor.run { self.status = "Snippet saved"; onSuccess(); self.reload() }
            } catch { await MainActor.run { self.status = error.localizedDescription } }
        }
    }
    func undoRemoval() {
        guard let removed = removedVocab, let client = client else { return }
        Task {
            do {
                try await client.restoreVocab(kind: removed.kind, key: removed.key, value: removed.value)
                await MainActor.run { self.removedVocab = nil; self.status = "Restored"; self.reload() }
            } catch { await MainActor.run { self.status = error.localizedDescription } }
        }
    }
    func undoLearning() {
        guard let id = undoSuggestionID, let client = client else { return }
        Task {
            do {
                try await client.undoSuggestion(id: id)
                await MainActor.run { self.undoSuggestionID = nil; self.status = "Undone"; self.reload(); self.loadSuggestions() }
            } catch { await MainActor.run { self.status = error.localizedDescription } }
        }
    }

    var client: ServerClient?

    func loadMics() {
        micDevices = AudioDevices.inputs()
        selectedMicUID = UserDefaults.standard.string(forKey: AudioDevices.defaultsKey) ?? ""
        prerollEnabled = UserDefaults.standard.object(forKey: "vf_preroll") as? Bool ?? true
    }

    func selectMic(_ uid: String) {
        selectedMicUID = uid
        UserDefaults.standard.set(uid, forKey: AudioDevices.defaultsKey)
        policyChanged()
    }

    func reload() {
        reloadRecovery()
        guard let client = client else { return }
        Task {
            do {
                let v = try await client.getVocab()
                let h = try await client.historyItems()
                await MainActor.run {
                    self.replacements = v.replacements.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
                    self.terms = v.terms
                    self.snippets = v.snippets.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
                    self.historyItems = h; self.history = h.map { $0.text }
                }
            } catch { await MainActor.run { self.status = "Refresh failed: \(error.localizedDescription)" } }
        }
    }

    func addReplacement(_ from: String, _ to: String, onSuccess: @escaping () -> Void = {}) {
        let f = from.trimmingCharacters(in: .whitespaces)
        let t = to.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !t.isEmpty, let client = client else { return }
        Task {
            do {
                try await client.addVocab(replacements: [f.lowercased(): t])
                await MainActor.run { self.status = "Added: \(f) → \(t)"; onSuccess() }
                self.reload()
            } catch {
                await MainActor.run { self.status = "Failed: \(error.localizedDescription)" }
            }
        }
    }

    func addTerm(_ term: String, onSuccess: @escaping () -> Void = {}) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let client = client else { return }
        Task {
            do {
                try await client.addVocab(terms: [t])
                await MainActor.run { self.status = "Added term: \(t)"; onSuccess() }
                self.reload()
            } catch {
                await MainActor.run { self.status = "Failed: \(error.localizedDescription)" }
            }
        }
    }

    /// Ping the server so the main window can show a connected/■ status dot.
    func pingServer() {
        guard let client = client else { return }
        Task {
            let ok = (try? await client.health()) != nil
            await MainActor.run { self.serverOK = ok }
        }
    }

    // MARK: - Learning (suggestions derived from your corrections + history)

    func loadSuggestions() {
        guard let client = client else { return }
        Task {
            do {
                let s = try await client.suggestions()
                await MainActor.run { self.suggestions = s }
            } catch { await MainActor.run { self.status = "Suggestions unavailable: \(error.localizedDescription)" } }
        }
    }

    func approveSuggestion(_ s: ServerClient.Suggestion) {
        guard let client = client else { return }
        Task {
            do {
                try await client.promoteSuggestion(id: s.id)
                await MainActor.run {
                    self.suggestions.removeAll { $0.id == s.id }
                    self.status = "Learned: \(s.label)"
                    self.undoSuggestionID = s.id
                }
                self.reload()   // refresh vocab lists to show the new entry
            } catch {
                await MainActor.run { self.status = "Failed: \(error.localizedDescription)" }
            }
        }
    }

    func dismissSuggestion(_ s: ServerClient.Suggestion) {
        guard let client = client else { return }
        Task {
            do {
                try await client.dismissSuggestion(id: s.id)
                await MainActor.run { self.suggestions.removeAll { $0.id == s.id }; self.undoSuggestionID = s.id }
            } catch { await MainActor.run { self.status = error.localizedDescription } }
        }
    }
}

private extension Color {
    static let vfInk = VF.Color.canvas(dark: true)
    static let vfAccent = VF.Color.accent
}

struct SettingsView: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        TabView {
            DictionaryTab(state: state).tabItem { Text("Dictionary") }
            LearningTab(state: state).tabItem { Text("Learning") }
            MicTab(state: state).tabItem { Text("Microphone") }
            HistoryTab(state: state).tabItem { Text("History") }
            AboutTab().tabItem { Text("About") }
        }
        .frame(width: 560, height: 460)
        .onAppear { state.reload(); state.loadMics(); state.loadSuggestions() }
    }
}

struct DictionaryTab: View {
    @ObservedObject var state: SettingsState
    private enum Category: String, CaseIterable { case corrections = "Corrections", terms = "Terms", snippets = "Snippets" }
    @State private var category = Category.corrections
    @State private var from = ""
    @State private var to = ""
    @State private var newTerm = ""
    @State private var trigger = ""
    @State private var expansion = ""
    @AppStorage("vf_myName") private var myName = ""
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var emptyCategory: Bool {
        switch category { case .corrections: return state.replacements.isEmpty; case .terms: return state.terms.isEmpty; case .snippets: return state.snippets.isEmpty }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: VF.Space.xl) {
            VStack(alignment: .leading, spacing: VF.Space.sm) {
                Text("Dictionary").font(VF.Font.display).tracking(VF.Tracking.display)
                Text("Choose spellings and reusable phrases.").font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark))
            }
            Picker("Dictionary category", selection: $category) {
                ForEach(Category.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            VStack(alignment: .leading, spacing: VF.Space.md) {
                switch category {
                case .corrections:
                    Text("Replace a word that was misheard with the spelling you want.").font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark))
                    HStack(spacing: VF.Space.md) {
                        TextField("Heard as, e.g. atelas", text: $from).textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(VF.Color.muted(dark: dark))
                        TextField("Write as, e.g. Atlas", text: $to).textFieldStyle(.roundedBorder)
                        Button("Save correction") { let f = from, t = to; state.addReplacement(f, t) { if from == f && to == t { from = ""; to = "" } } }
                            .buttonStyle(VFActionStyle()).disabled(from.trimmingCharacters(in: .whitespaces).isEmpty || to.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                case .terms:
                    Text("Keep names, product names, and specialist words spelled consistently.").font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark))
                    HStack(spacing: VF.Space.md) {
                        TextField("Add a term, e.g. Project Atlas", text: $newTerm).textFieldStyle(.roundedBorder)
                        Button("Add term") { let term = newTerm; state.addTerm(term) { if newTerm == term { newTerm = "" } } }
                            .buttonStyle(VFActionStyle()).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                case .snippets:
                    Text("Say a short trigger to insert a longer phrase. Review an expansion before using it.").font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark))
                    HStack {
                        TextField("Spoken trigger, e.g. my sign-off", text: $trigger).textFieldStyle(.roundedBorder)
                        Button("Save snippet") {
                            let t = trigger, e = expansion
                            state.addSnippet(t, e) { if trigger == t && expansion == e { trigger = ""; expansion = "" } }
                        }.buttonStyle(VFActionStyle()).disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    TextEditor(text: $expansion).font(VF.Font.callout).frame(height: 88).padding(VF.Space.sm)
                        .background(VF.Color.surface(dark: dark), in: RoundedRectangle(cornerRadius: VF.Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: VF.Radius.sm).stroke(VF.Color.border(dark: dark)))
                        .accessibilityLabel("Snippet expansion")
                }
            }.controlSize(.large)
            Divider()
            List {
                switch category {
                case .corrections:
                    ForEach(state.replacements, id: \.0) { item in
                        HStack(spacing: VF.Space.md) {
                            Text(item.0).foregroundStyle(VF.Color.muted(dark: dark)); Image(systemName: "arrow.right").foregroundStyle(VF.Color.muted(dark: dark)); Text(item.1)
                            Spacer()
                            Button("Edit") { from = item.0; to = item.1 }.buttonStyle(.plain)
                            removeMenu(kind: "replacements", key: item.0, value: item.1)
                        }.padding(.vertical, VF.Space.sm)
                    }
                case .terms:
                    ForEach(state.terms, id: \.self) { term in
                        HStack { Text(term); Spacer(); removeMenu(kind: "terms", key: term, value: term) }.padding(.vertical, VF.Space.sm)
                    }
                case .snippets:
                    ForEach(state.snippets, id: \.0) { item in
                        HStack(alignment: .top, spacing: VF.Space.md) {
                            VStack(alignment: .leading, spacing: VF.Space.sm) {
                                Text(item.0).font(VF.Font.heading)
                                Text(item.1).foregroundStyle(VF.Color.muted(dark: dark)).lineLimit(3)
                            }
                            Spacer()
                            Button("Edit") { trigger = item.0; expansion = item.1 }.buttonStyle(.plain)
                            removeMenu(kind: "snippets", key: item.0, value: item.1)
                        }.padding(.vertical, VF.Space.sm)
                    }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).font(VF.Font.callout)
                .overlay { if emptyCategory { Text("No \(category.rawValue.lowercased()) yet. Add one above.").font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark)) } }
            if state.removedVocab != nil { Button("Undo removal") { state.undoRemoval() }.buttonStyle(VFActionStyle()) }
            if !state.status.isEmpty { Text(state.status).font(VF.Font.callout).textSelection(.enabled) }
            DisclosureGroup("Your name in meeting notes") {
                HStack {
                    TextField("Your name", text: $myName).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    Text("Highlights your action items. Leave empty to turn off.").font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: dark))
                }.padding(.top, VF.Space.sm)
            }.font(VF.Font.callout)
        }.padding(VF.Space.xxl).foregroundStyle(VF.Color.ink(dark: dark))
    }
    private func removeMenu(kind: String, key: String, value: String) -> some View {
        Menu { Button("Remove", role: .destructive) { state.removeVocab(kind: kind, key: key, value: value) } }
            label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Options for \(key)")
    }
}

struct LearningTab: View {
    @ObservedObject var state: SettingsState
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Learning").font(VF.Font.display)
                        Text("A dictionary that learns with your approval.").foregroundStyle(VF.Color.muted(dark: dark))
                    }
                    Spacer()
                    Button("Refresh") { state.loadSuggestions() }.buttonStyle(VFActionStyle())
                }
                Text("Review recurring corrections and names from your history. Approving a suggestion adds it to Dictionary; dismissing leaves your words unchanged.")
                    .font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark)).fixedSize(horizontal: false, vertical: true)
                if state.suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Nothing to review").font(VF.Font.title)
                        Text("Use Correct last dictation in the menu bar to teach WhisperType a correction. Suggestions will appear here as it notices a pattern.")
                            .foregroundStyle(VF.Color.muted(dark: dark))
                    }.padding(.vertical, 24)
                } else {
                    VStack(spacing: 0) {
                        ForEach(state.suggestions) { suggestion in
                            HStack(spacing: 18) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(suggestion.label).font(VF.Font.body).textSelection(.enabled)
                                    Text((suggestion.kind == "replacement" ? "Correction" : "Term") + " · Seen \(suggestion.count) times" + (suggestion.source == "scan" ? " in history" : ""))
                                        .font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: dark))
                                }
                                Spacer(minLength: 12)
                                Button("Approve") { state.approveSuggestion(suggestion) }.buttonStyle(VFActionStyle())
                                    .accessibilityLabel("Approve \(suggestion.label)")
                                Button { state.dismissSuggestion(suggestion) } label: { Image(systemName: "xmark").frame(width: 18, height: 18) }
                                    .buttonStyle(VFActionStyle()).accessibilityLabel("Dismiss \(suggestion.label)")
                            }.padding(.vertical, 20)
                            Divider()
                        }
                    }
                }
                if state.undoSuggestionID != nil { Button("Undo last action") { state.undoLearning() }.buttonStyle(VFActionStyle()) }
                if !state.status.isEmpty { Text(state.status).font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark)).textSelection(.enabled) }
            }.font(VF.Font.body).frame(maxWidth: 760, alignment: .leading).padding(32).frame(maxWidth: .infinity, alignment: .top)
        }.background(VF.Color.canvas(dark: dark))
    }
}

struct MicTab: View {
    @ObservedObject var state: SettingsState
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Microphone").font(VF.Font.display)
                    Text("Choose what listens, and when.").foregroundStyle(VF.Color.muted(dark: dark))
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Input").font(VF.Font.title)
                        Spacer()
                        Button("Refresh") { state.loadMics() }.buttonStyle(VFActionStyle())
                    }
                    Picker("Microphone", selection: Binding(get: { state.selectedMicUID }, set: { state.selectMic($0) })) {
                        Text("System default").tag("")
                        ForEach(state.micDevices) { device in Text(device.name).tag(device.uid) }
                    }.pickerStyle(.menu).frame(maxWidth: 440, alignment: .leading)
                    Label(state.activeMicName, systemImage: "mic").font(VF.Font.callout)
                    Text("If this microphone cannot start, WhisperType tries another permitted physical input. The active device is shown here and in the pill.")
                        .font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark))
                }
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Between recordings").font(VF.Font.title)
                    Toggle("Capture the moment before I start", isOn: $state.prerollEnabled)
                    Text("Keeps the microphone warm and buffers the preceding 1.5 seconds in memory. With this off, wait for Listening before speaking. Changes during capture apply when it stops.")
                        .font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark))
                    Toggle("Allow Bluetooth microphones", isOn: $state.allowBluetooth)
                    Toggle("Keep Bluetooth input warm", isOn: $state.bluetoothWarm)
                        .disabled(!state.allowBluetooth || !state.prerollEnabled)
                    Text("Bluetooth microphone use can reduce headset playback quality. Turning warming off releases Bluetooth input when you stop.")
                        .font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark))
                }
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("Access").font(VF.Font.title); Spacer(); Button("Check again") { state.onCheckPermissions?(); state.pingServer() }.buttonStyle(VFActionStyle()) }
                    accessRow("Microphone", detail: "Capture your voice", status: state.microphonePermission, action: state.onRequestMicrophone)
                    accessRow("Accessibility", detail: "Type into your chosen destination", status: state.accessibilityPermission, action: state.onRequestAccessibility)
                    accessRow("Screen Recording", detail: "Include system audio in meetings", status: state.screenPermission, action: state.onRequestScreen)
                }
                if !state.status.isEmpty { Text(state.status).font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark)).textSelection(.enabled) }
            }.font(VF.Font.body).frame(maxWidth: 760, alignment: .leading).padding(32).frame(maxWidth: .infinity, alignment: .top)
        }.background(VF.Color.canvas(dark: dark))
    }
    private func accessRow(_ name: String, detail: String, status: String, action: (() -> Void)?) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) { Text(name); Text(detail).font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: dark)) }
            Spacer()
            if status == "Allowed" { Label("Allowed", systemImage: "checkmark").font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark)) }
            else { Button("Allow \(name)") { action?() }.buttonStyle(VFActionStyle()) }
        }.padding(.vertical, 4)
    }
}

struct HistoryTab: View {
    @ObservedObject var state: SettingsState
    var onlyRecovery = false
    @State private var search = ""
    @State private var discard: RecordingStore.Entry?
    @State private var deleteID: Int?
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var history: [ServerClient.HistoryItem] { state.historyItems.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: VF.Space.sm) {
                    Text(onlyRecovery ? "Inbox" : "Dictation history").font(VF.Font.display).tracking(VF.Tracking.display)
                    Text(onlyRecovery ? "Review a result or pick up where a recording stopped." : "Find something you said. Copy it, or remove it from server history.")
                        .font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark))
                }
                Spacer()
                Button { state.reload() } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).help("Refresh").accessibilityLabel("Refresh recordings")
                Menu {
                    Button("Open recordings folder") { NSWorkspace.shared.open(RecordingStore.recordingsDirectory()) }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Recording options")
            }.padding(.bottom, VF.Space.xl)
            if !onlyRecovery {
                HStack(spacing: VF.Space.sm) {
                    Image(systemName: "magnifyingglass").foregroundStyle(VF.Color.muted(dark: dark))
                    TextField("Search dictations", text: $search).textFieldStyle(.plain)
                }.padding(VF.Space.md).background(VF.Color.surfaceHover(dark: dark), in: RoundedRectangle(cornerRadius: VF.Radius.sm))
                    .padding(.bottom, VF.Space.lg)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if onlyRecovery {
                        if state.recoveryEntries.isEmpty && state.interruptedMeetings.isEmpty {
                            empty("All caught up.", detail: "Results that need review and saved audio that can be retried will appear here.", symbol: "tray")
                        }
                        ForEach(state.interruptedMeetings, id: \.path) { directory in
                            VStack(alignment: .leading, spacing: VF.Space.md) {
                                Label("Interrupted meeting", systemImage: "waveform.badge.exclamationmark").font(VF.Font.heading)
                                Text("Audio fragments are saved on this Mac. Recover them into a recording you can open or import.")
                                    .font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark))
                                Button("Recover recording") { state.recoverMeeting(directory) }.buttonStyle(VFActionStyle())
                            }.padding(.vertical, VF.Space.xl)
                            Divider()
                        }
                        ForEach(state.recoveryEntries) { entry in
                            recoveryRow(entry).padding(.vertical, VF.Space.xl)
                            Divider()
                        }
                    } else {
                        if history.isEmpty { empty(search.isEmpty ? "Your dictations will be here." : "No matching dictations.", detail: search.isEmpty ? "Completed dictations are stored on your configured server." : "Try a different word or phrase.", symbol: "text.magnifyingglass") }
                        ForEach(history) { item in
                            VStack(alignment: .leading, spacing: VF.Space.md) {
                                HStack {
                                    Text(item.timestamp).font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: dark))
                                    Spacer()
                                    Button("Copy") { copy(item.text) }.buttonStyle(.plain).font(VF.Font.callout)
                                    Menu { Button("Delete from server history", role: .destructive) { deleteID = item.id } }
                                        label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Dictation options")
                                }
                                Text(item.text).font(VF.Font.body).lineSpacing(5).textSelection(.enabled)
                            }.padding(.vertical, VF.Space.xl)
                            Divider()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !state.status.isEmpty {
                Text(state.status).font(VF.Font.callout).textSelection(.enabled).padding(.top, VF.Space.md)
            }
            Text(onlyRecovery ? "Saved on this Mac until sent or removed. Server history and backups are separate." : "Deleting server history also removes its stored audio. Existing backups are separate.")
                .font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: dark)).padding(.top, VF.Space.lg)
        }
        .foregroundStyle(VF.Color.ink(dark: dark)).padding(VF.Space.xxl)
        .onAppear { state.reloadRecovery() }
        .onReceive(NotificationCenter.default.publisher(for: .vfRecordingsChanged)) { _ in state.reloadRecovery() }
        .alert("Remove this recording?", isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } })) {
            Button("Remove", role: .destructive) { if let entry = discard { state.discardRecording(entry.id) }; discard = nil }
            Button("Cancel", role: .cancel) { discard = nil }
        } message: { Text("This removes the local audio and result. Server history and backups are separate.") }
        .alert("Delete this dictation?", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
            Button("Delete", role: .destructive) { if let id = deleteID { state.deleteHistory(id) }; deleteID = nil }
            Button("Cancel", role: .cancel) { deleteID = nil }
        } message: { Text("This permanently removes the dictation and its audio from server history. Backups are separate.") }
    }
    private func recoveryRow(_ entry: RecordingStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: VF.Space.md) {
            HStack(spacing: VF.Space.sm) {
                Image(systemName: entry.kind == "prompt" ? "text.bubble" : "mic").foregroundStyle(VF.Color.muted(dark: dark))
                Text(entry.kind.capitalized).font(VF.Font.heading)
                Spacer()
                Text(entry.created.formatted(date: .abbreviated, time: .shortened)).font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: dark))
                Menu {
                    Button("Open audio") { NSWorkspace.shared.open(RecordingStore.audioURL(entry.id)) }
                        .disabled(!FileManager.default.fileExists(atPath: RecordingStore.audioURL(entry.id).path))
                    if !entry.text.isEmpty { Button("Copy result") { copy(entry.text) } }
                    Divider()
                    Button("Remove recording…", role: .destructive) { discard = entry }.disabled(entry.status == "processing")
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("\(entry.kind.capitalized) options")
            }
            if !entry.text.isEmpty { Text(entry.text).font(VF.Font.body).lineSpacing(5).lineLimit(4).textSelection(.enabled) }
            HStack(alignment: .center, spacing: VF.Space.lg) {
                if entry.status == "processing" {
                    ProgressView().controlSize(.small)
                    Text("Processing recording…").font(VF.Font.callout)
                    Spacer()
                    Button("Cancel processing") { state.onCancelRecording?(entry.id) }.buttonStyle(VFActionStyle())
                } else {
                    Label(entry.error.isEmpty ? (entry.text.isEmpty ? "Audio saved" : "Ready for review") : entry.error,
                          systemImage: entry.text.isEmpty ? "arrow.clockwise" : "tray")
                        .font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(entry.text.isEmpty && entry.variants.isEmpty ? "Retry" : "Review result") {
                        if entry.text.isEmpty && entry.variants.isEmpty { state.onRetryRecording?(entry.id) }
                        else { state.onReviewRecording?(entry.id) }
                    }.buttonStyle(VFActionStyle(entry.text.isEmpty ? .secondary : .primary))
                }
            }
        }
    }
    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: VF.Space.md) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(VF.Color.muted(dark: dark)).accessibilityHidden(true)
            Text(title).font(VF.Font.title)
            Text(detail).font(VF.Font.body).foregroundStyle(VF.Color.muted(dark: dark)).frame(maxWidth: 440, alignment: .leading)
        }.padding(.vertical, VF.Space.xxxl).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

struct AboutTab: View {
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 16) {
                    Image(systemName: "waveform").font(.system(size: 32)).foregroundStyle(VF.Color.accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WhisperType").font(VF.Font.display)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unbundled build")")
                            .font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: dark)).textSelection(.enabled)
                    }
                }
                Text("Speak a dictation, shape a prompt, or keep a meeting.").font(VF.Font.title)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your words and recordings").font(VF.Font.title)
                    Text("Inference runs on your configured server. Audio and transcripts stay available for recovery until removed; successful verified insertion releases the local dictation audio. Server history and meeting transcripts have separate removal controls.")
                    Text("If you use the backup workflow, its destination may sync recordings and transcripts to cloud storage. Removing an item here does not remove an existing backup.")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Across your Macs").font(VF.Font.title)
                    Text("Hold Right Option in a destination app, or use Record to keep a result in Inbox. Screen Sharing insertion requires a paired agent on the destination Mac. A changed destination leaves your result ready for review.")
                }
            }.font(VF.Font.body).foregroundStyle(VF.Color.ink(dark: dark)).frame(maxWidth: 720, alignment: .leading).padding(40).frame(maxWidth: .infinity, alignment: .top)
        }.background(VF.Color.canvas(dark: dark))
    }
}

/// Hosts SettingsView in a normal window opened from the menu bar.
final class SettingsWindowController {
    private var window: NSWindow?
    let state = SettingsState()

    func show(client: ServerClient) {
        state.client = client
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(state: state))
            let w = NSWindow(contentViewController: hosting)
            w.title = "whispertype Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(NSSize(width: 560, height: 460))
            w.isReleasedWhenClosed = false
            window = w
        }
        state.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
