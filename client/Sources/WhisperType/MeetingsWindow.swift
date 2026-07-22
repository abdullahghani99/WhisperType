import SwiftUI
import AppKit

/// Backing state for the Meetings window — lists jobs from the server and loads
/// a selected meeting's transcript + notes. Polls while any job is processing.
final class MeetingsState: ObservableObject {
    @Published var items: [ServerClient.MeetingSummary] = []
    @Published var selected: ServerClient.Meeting?
    @Published var loadingDetail = false
    var client: ServerClient?
    private var timer: Timer?

    func refresh() {
        guard let client = client else { return }
        Task {
            let list = (try? await client.meetings()) ?? []
            await MainActor.run {
                self.items = list
                // Auto-poll every 5s while anything is still processing.
                let anyProcessing = list.contains { $0.status == "processing" }
                if anyProcessing && self.timer == nil {
                    self.timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                        self?.refresh()
                    }
                } else if !anyProcessing {
                    self.timer?.invalidate(); self.timer = nil
                }
            }
        }
    }

    func open(_ id: Int) {
        guard let client = client else { return }
        loadingDetail = true
        Task {
            let m = try? await client.meeting(id: id)
            await MainActor.run { self.selected = m; self.loadingDetail = false }
        }
    }

    func markdown(for m: ServerClient.Meeting, title: String) -> String {
        """
        # Meeting notes — \(title)

        \(m.notes)

        ---

        ## Full transcript

        \(m.transcript)
        """
    }
}

private extension Color {
    static let vfAccent = Color(red: 0xE7/255, green: 0x00/255, blue: 0x0B/255)
}

struct MeetingsView: View {
    @ObservedObject var state: MeetingsState

    var body: some View {
        HSplitView {
            // Left: job list
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(state.items.count) recorded").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { state.refresh() }.controlSize(.small)
                }.padding([.top, .horizontal], 12)
                List(state.items) { m in
                    HStack(spacing: 8) {
                        statusDot(m.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title.isEmpty ? "Meeting \(m.id)" : m.title)
                                .font(.callout).lineLimit(1)
                            Text(subtitle(m)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .background(state.selected?.id == m.id ? Color.vfAccent.opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { state.open(m.id) }
                }
            }.frame(minWidth: 240, maxWidth: 320)

            // Right: detail
            detail.frame(minWidth: 420)
        }
        .onAppear { state.refresh() }
    }

    @ViewBuilder private var detail: some View {
        if state.loadingDetail {
            VStack { Spacer(); ProgressView("Loading…"); Spacer() }.frame(maxWidth: .infinity)
        } else if let m = state.selected {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(m.speakers > 0 ? "\(m.speakers) speakers" : "Transcript & notes")
                        .font(.headline)
                    Spacer()
                    Button("Save .md to Desktop") { save(m) }
                }
                if m.status == "processing" {
                    Label("Still processing on the server… this window auto-updates.",
                          systemImage: "clock").foregroundStyle(.secondary)
                } else if m.status == "error" {
                    Label(m.error.isEmpty ? "Failed" : m.error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.vfAccent)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !m.notes.isEmpty {
                            Text(rendered(m.notes)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !m.transcript.isEmpty {
                            Divider()
                            Text("FULL TRANSCRIPT").font(.caption).foregroundStyle(.secondary)
                            Text(rendered(m.transcript)).font(.callout).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if m.notes.isEmpty && m.transcript.isEmpty && m.status != "processing" {
                            Text("(no content)").foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(14)
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "text.bubble").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("Select a meeting to view its notes and transcript").foregroundStyle(.secondary)
                Spacer()
            }.frame(maxWidth: .infinity)
        }
    }

    /// Render Markdown (bold, bullets) while preserving line breaks, so notes
    /// show properly instead of literal ** and - characters.
    private func rendered(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private func subtitle(_ m: ServerClient.MeetingSummary) -> String {
        switch m.status {
        case "processing": return "⏳ processing…"
        case "error": return "⚠︎ \(m.error.isEmpty ? "failed" : m.error)"
        default:
            var s = m.ts
            if m.speakers > 0 { s += " · \(m.speakers) speakers" }
            return s
        }
    }

    @ViewBuilder private func statusDot(_ status: String) -> some View {
        let c: Color = status == "done" ? .green : status == "error" ? .red : .orange
        Circle().fill(c).frame(width: 8, height: 8)
    }

    private func save(_ m: ServerClient.Meeting) {
        let title = (state.items.first { $0.id == m.id }?.title) ?? "Meeting \(m.id)"
        let md = state.markdown(for: m, title: title)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title.replacingOccurrences(of: "/", with: "-")).md"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? md.data(using: .utf8)!.write(to: url)
            NSWorkspace.shared.open(url)
        }
    }
}

/// Hosts MeetingsView in a window opened from the menu bar.
final class MeetingsWindowController {
    private var window: NSWindow?
    let state = MeetingsState()

    func show(client: ServerClient) {
        state.client = client
        if window == nil {
            let hosting = NSHostingController(rootView: MeetingsView(state: state))
            let w = NSWindow(contentViewController: hosting)
            w.title = "WhisperType Meetings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 820, height: 560))
            w.isReleasedWhenClosed = false
            window = w
        }
        state.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
