import SwiftUI
import AppKit

/// Backing state for the settings window: talks to the server's /vocab and
/// /history endpoints. @Published writes are marshalled to the main thread.
final class SettingsState: ObservableObject {
    @Published var replacements: [(String, String)] = []
    @Published var terms: [String] = []
    @Published var snippets: [(String, String)] = []
    @Published var history: [String] = []
    @Published var status: String = ""

    var client: ServerClient?

    func reload() {
        guard let client = client else { return }
        Task {
            let v = try? await client.getVocab()
            let h = try? await client.recent(limit: 50)
            await MainActor.run {
                if let v = v {
                    self.replacements = v.replacements.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
                    self.terms = v.terms
                    self.snippets = v.snippets.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
                }
                if let h = h { self.history = h }
            }
        }
    }

    func addReplacement(_ from: String, _ to: String) {
        let f = from.trimmingCharacters(in: .whitespaces)
        let t = to.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !t.isEmpty, let client = client else { return }
        Task {
            do {
                try await client.addVocab(replacements: [f.lowercased(): t])
                await MainActor.run { self.status = "Added: \(f) → \(t)" }
                self.reload()
            } catch {
                await MainActor.run { self.status = "Failed: \(error.localizedDescription)" }
            }
        }
    }

    func addTerm(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let client = client else { return }
        Task {
            do {
                try await client.addVocab(terms: [t])
                await MainActor.run { self.status = "Added term: \(t)" }
                self.reload()
            } catch {
                await MainActor.run { self.status = "Failed: \(error.localizedDescription)" }
            }
        }
    }
}

private extension Color {
    static let vfInk = Color(red: 0x1A/255, green: 0x17/255, blue: 0x14/255)
    static let vfAccent = Color(red: 0xE7/255, green: 0x00/255, blue: 0x0B/255)
}

struct SettingsView: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        TabView {
            DictionaryTab(state: state).tabItem { Text("Dictionary") }
            HistoryTab(state: state).tabItem { Text("History") }
            AboutTab().tabItem { Text("About") }
        }
        .frame(width: 560, height: 460)
        .onAppear { state.reload() }
    }
}

private struct DictionaryTab: View {
    @ObservedObject var state: SettingsState
    @State private var from = ""
    @State private var to = ""
    @State private var newTerm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Corrections").font(.headline)
            Text("When Whisper mishears a word, add a fix. Applies instantly to every dictation.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("heard (e.g. faroq)", text: $from).textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("correct (e.g. Kubernetes)", text: $to).textFieldStyle(.roundedBorder)
                Button("Add") { state.addReplacement(from, to); from = ""; to = "" }
                    .disabled(from.isEmpty || to.isEmpty)
            }

            Divider()
            Text("Vocabulary (names & jargon)").font(.headline)
            Text("Terms Whisper should spell correctly and the polisher should keep exact.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("add a term (e.g. PostgreSQL)", text: $newTerm).textFieldStyle(.roundedBorder)
                Button("Add") { state.addTerm(newTerm); newTerm = "" }.disabled(newTerm.isEmpty)
            }

            List {
                if !state.replacements.isEmpty {
                    Section("Corrections (\(state.replacements.count))") {
                        ForEach(state.replacements, id: \.0) { r in
                            HStack { Text(r.0); Image(systemName: "arrow.right").foregroundStyle(.secondary); Text(r.1).bold() }
                        }
                    }
                }
                Section("Terms (\(state.terms.count))") {
                    Text(state.terms.joined(separator: ", ")).font(.callout)
                }
            }
            if !state.status.isEmpty {
                Text(state.status).font(.caption).foregroundStyle(Color.vfAccent)
            }
        }
        .padding(16)
    }
}

private struct HistoryTab: View {
    @ObservedObject var state: SettingsState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent dictations").font(.headline)
                Spacer()
                Button("Refresh") { state.reload() }
            }
            List(Array(state.history.enumerated()), id: \.offset) { _, text in
                HStack(alignment: .top) {
                    Text(text).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
                }
            }
        }
        .padding(16)
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.fill").font(.system(size: 34)).foregroundStyle(Color.vfAccent)
            Text("WhisperType").font(.title2).bold()
            Text("Hold Right-Option (⌥) to dictate. Runs on your own Mac.\nWorks over Screen Sharing. Private — nothing leaves your network.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(30)
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
            w.title = "WhisperType Settings"
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
