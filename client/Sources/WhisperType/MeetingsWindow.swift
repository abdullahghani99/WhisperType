import SwiftUI
import AppKit
import WhisperTypeKit

/// Backing state for the Meetings window — lists jobs from the server and loads
/// a selected meeting's transcript + notes. Polls while any job is processing.
final class MeetingsState: ObservableObject {
    @Published var items: [ServerClient.MeetingSummary] = []
    @Published var selected: ServerClient.Meeting?
    @Published var loadingDetail = false
    /// Set when the server could not be reached or refused a change. Every call
    /// here used to swallow its error with `try?`, so a failed rename did nothing
    /// visible and a dead server rendered identically to an empty account.
    @Published var loadError: String?
    var client: ServerClient?
    private var timer: Timer?

    func refresh() {
        guard let client = client else { return }
        Task {
            do {
                let list = try await client.meetings()
                await MainActor.run {
                    self.loadError = nil
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
            } catch {
                await MainActor.run {
                    // Keep whatever was already listed — losing it as well as the
                    // connection helps nobody.
                    self.loadError = error.localizedDescription
                    self.timer?.invalidate(); self.timer = nil
                }
            }
        }
    }

    func open(_ id: Int) {
        guard let client = client else { return }
        loadingDetail = true
        Task {
            do {
                let m = try await client.meeting(id: id)
                await MainActor.run {
                    self.selected = m; self.loadingDetail = false; self.loadError = nil
                }
            } catch {
                await MainActor.run {
                    self.loadingDetail = false
                    self.loadError = error.localizedDescription
                }
            }
        }
    }

    func rename(_ id: Int, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = client, !clean.isEmpty else { return }
        Task {
            do {
                try await client.renameMeeting(id: id, title: clean)
                await MainActor.run { self.loadError = nil; self.refresh() }
            } catch {
                await MainActor.run { self.loadError = error.localizedDescription }
            }
        }
    }

    func renameSpeaker(_ id: Int, from: String, to: String) {
        let clean = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = client, !clean.isEmpty else { return }
        Task {
            do {
                try await client.renameSpeaker(id: id, from: from, to: clean)
                await MainActor.run { self.loadError = nil; self.open(id) }  // reload with the new names
            } catch {
                await MainActor.run { self.loadError = error.localizedDescription }
            }
        }
    }

    func delete(_ id: Int) {
        guard let client = client else { return }
        Task {
            do {
                try await client.deleteMeeting(id: id)
                await MainActor.run {
                    self.loadError = nil
                    if self.selected?.id == id { self.selected = nil }
                    self.refresh()
                }
            } catch {
                await MainActor.run { self.loadError = error.localizedDescription }
            }
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

struct MeetingsView: View {
    @ObservedObject var state: MeetingsState
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    private enum Tab: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }
    @State private var tab: Tab = .summary

    var body: some View {
        HSplitView {
            // Left: meeting list. Titles wrap to two lines and are never
            // truncated — findability is the whole point of auto-titles.
            VStack(alignment: .leading, spacing: VF.Space.xs) {
                HStack {
                    // Never claim a count we could not fetch — "0 recorded" made
                    // a dead server look exactly like an empty account.
                    Text(state.loadError == nil
                         ? "\(state.items.count) recorded"
                         : "Not loaded")
                        .font(VF.Font.caption)
                        .foregroundColor(VF.Color.muted(dark: dark))
                    Spacer()
                    Button("Refresh") { state.refresh() }.controlSize(.small)
                }
                .padding([.top, .horizontal], VF.Space.md)

                if let err = state.loadError {
                    listNotice("Can\u{2019}t reach the server.", detail: err, isError: true)
                } else if state.items.isEmpty {
                    listNotice("No meetings yet.",
                               detail: "Record one from the dock.", isError: false)
                }

                List(state.items) { m in
                    let isSelected = state.selected?.id == m.id
                    HStack(alignment: .top, spacing: 0) {
                        // Accent rail marks the row you are reading. Identity and
                        // active state is precisely what the accent is reserved for.
                        Rectangle()
                            .fill(isSelected ? VF.Color.accent : Color.clear)
                            .frame(width: 2)
                        HStack(alignment: .top, spacing: VF.Space.sm) {
                            statusDot(m.status)
                                .padding(.top, VF.Space.xs)
                            VStack(alignment: .leading, spacing: VF.Space.xs) {
                                Text(VF.sentenceCase(m.title.isEmpty ? "Meeting \(m.id)" : m.title))
                                    .font(VF.Font.body)
                                    .foregroundColor(VF.Color.ink(dark: dark))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(subtitle(m))
                                    .font(VF.Font.caption)
                                    .foregroundColor(VF.Color.muted(dark: dark))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, VF.Space.sm)
                        .padding(.vertical, VF.Space.xs)
                    }
                    // The list itself sits on surfaceHover, so the SELECTED row
                    // must lift to `surface` — filling it with surfaceHover too
                    // gave it zero contrast and made the selection invisible.
                    .background(isSelected ? VF.Color.surface(dark: dark) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { state.open(m.id) }
                    .contextMenu {
                        Button("Rename\u{2026}") { promptRename(m) }
                        Button("Delete", role: .destructive) { confirmDelete(m) }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(VF.Color.surfaceHover(dark: dark))
            }
            .frame(minWidth: 280, maxWidth: 320)

            // Right: detail
            detail.frame(minWidth: 420)
        }
        .onAppear { state.refresh() }
    }

    /// The list column's own state message. An empty account and an unreachable
    /// server are different facts and must not look the same. The raw server
    /// error is never shown — it goes to the tooltip, where it helps whoever is
    /// debugging without shouting at whoever is not.
    @ViewBuilder private func listNotice(_ title: String, detail: String,
                                         isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: VF.Space.xs) {
            Text(title)
                .font(VF.Font.body)
                .foregroundColor(isError ? VF.Color.accent : VF.Color.ink(dark: dark))
            Text(isError ? "Check that it\u{2019}s running, then hit refresh." : detail)
                .font(VF.Font.caption)
                .foregroundColor(VF.Color.muted(dark: dark))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VF.Space.md)
        .padding(.vertical, VF.Space.sm)
        .help(isError ? detail : "")
    }

    @ViewBuilder private var detail: some View {
        if state.loadingDetail {
            VStack { Spacer(); ProgressView("Loading\u{2026}"); Spacer() }
                .frame(maxWidth: .infinity)
                .background(VF.Color.canvas(dark: dark))
        } else if let m = state.selected {
            let summary = state.items.first { $0.id == m.id }
            ScrollView {
                VStack(alignment: .leading, spacing: VF.Space.lg) {
                    // The name of the thing leads. Serif display — this is what
                    // makes a meeting read as a document, not a database row.
                    Text(VF.sentenceCase(summary?.title.isEmpty == false
                                         ? summary!.title : "Meeting \(m.id)"))
                        .font(VF.Font.display)
                        .tracking(VF.Tracking.display)
                        .foregroundColor(VF.Color.ink(dark: dark))
                        .lineSpacing(VF.Leading.display)
                        .fixedSize(horizontal: false, vertical: true)

                    metaRow(m, summary)

                    tabBar

                    speakerBar(m)

                    if m.status == "processing" {
                        Label("Still processing on the server. This updates itself.",
                              systemImage: "clock")
                            .font(VF.Font.body)
                            .foregroundColor(VF.Color.muted(dark: dark))
                    } else if m.status == "error" {
                        Label(m.error.isEmpty ? "This one failed to process." : m.error,
                              systemImage: "exclamationmark.triangle")
                            .font(VF.Font.body)
                            .foregroundColor(VF.Color.accent)
                    }

                    if tab == .summary {
                        if m.notes.isEmpty {
                            Text("No notes for this meeting.")
                                .font(VF.Font.body)
                                .foregroundColor(VF.Color.muted(dark: dark))
                        } else {
                            notesBody(m.notes)
                        }
                    } else {
                        if m.transcript.isEmpty {
                            Text("No transcript for this meeting.")
                                .font(VF.Font.body)
                                .foregroundColor(VF.Color.muted(dark: dark))
                        } else {
                            Text(rendered(m.transcript))
                                .font(VF.Font.body)
                                .lineSpacing(VF.Leading.body)
                                .foregroundColor(VF.Color.body(dark: dark))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                // ~68ch measure, centred, with real breathing room. This single
                // constraint is what turns a dense pane into a readable document.
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, VF.Space.xxl)
                .padding(.vertical, VF.Space.xxxl)
                .frame(maxWidth: .infinity)
            }
            .background(VF.Color.canvas(dark: dark))
        } else {
            emptyState
        }
    }

    /// Render Markdown (bold, bullets) while preserving line breaks, so notes
    /// show properly instead of literal ** and - characters.
    private func rendered(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    /// Read time and the meeting's actions. Destructive action is separated from
    /// the primary ones so Delete cannot be hit by muscle memory. The chip must
    /// describe what the ACTIVE TAB shows — not the whole meeting — or "51 min
    /// read" next to a one-minute summary is actively misleading.
    @ViewBuilder private func metaRow(_ m: ServerClient.Meeting,
                                      _ summary: ServerClient.MeetingSummary?) -> some View {
        let text = tab == .summary ? m.notes : m.transcript
        HStack(spacing: VF.Space.md) {
            Text(VF.readTime(wordCount: text
                                .split(whereSeparator: { $0 == " " || $0 == "\n" }).count))
                .font(VF.Font.caption)
                .tracking(VF.Tracking.caption)
                .foregroundColor(VF.Color.muted(dark: dark))
                .padding(.horizontal, VF.Space.sm)
                .padding(.vertical, VF.Space.xs)
                .background(
                    RoundedRectangle(cornerRadius: VF.Radius.sm)
                        .fill(VF.Color.surfaceHover(dark: dark))
                )

            Spacer()

            if let s = summary {
                Button("Rename") { promptRename(s) }.controlSize(.small)
                Button("Export notes\u{2026}") { save(m) }.controlSize(.small)
                Divider().frame(height: 14)
                Button("Delete") { confirmDelete(s) }
                    .controlSize(.small)
                    .foregroundColor(VF.Color.accent)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: VF.Space.lg) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    VStack(spacing: VF.Space.xs) {
                        Text(t.rawValue)
                            .font(VF.Font.callout)
                            .foregroundColor(tab == t
                                             ? VF.Color.ink(dark: dark)
                                             : VF.Color.muted(dark: dark))
                        Rectangle()
                            .fill(tab == t ? VF.Color.ink(dark: dark) : Color.clear)
                            .frame(height: 1.5)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: VF.Space.md) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.system(size: 30))
                .foregroundColor(VF.Color.faint(dark: dark))
            Text("Nothing selected")
                .font(VF.Font.title)
                .foregroundColor(VF.Color.ink(dark: dark))
            Text("Pick a meeting on the left, or record one from the dock.")
                .font(VF.Font.body)
                .foregroundColor(VF.Color.muted(dark: dark))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(VF.Color.canvas(dark: dark))
    }

    /// Render the notes markdown with genuine typographic hierarchy: serif
    /// section headings, body copy at a readable measure, real bullets, and the
    /// reader's own action items promoted above the rest.
    @ViewBuilder private func notesBody(_ notes: String) -> some View {
        let blocks = Self.splitSections(notes)
        VStack(alignment: .leading, spacing: VF.Space.xl) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                VStack(alignment: .leading, spacing: VF.Space.sm) {
                    if !block.heading.isEmpty {
                        Text(block.heading)
                            .font(VF.Font.sectionHeading)
                            .foregroundColor(VF.Color.ink(dark: dark))
                    }
                    ForEach(Array(block.lines.enumerated()), id: \.offset) { _, text in
                        notesLine(text)
                    }
                }
            }
        }
    }

    /// One notes line. Markdown is parsed inline-only (to preserve line breaks),
    /// so a "- item" would otherwise render as a literal hyphen — which is the
    /// main reason the notes still read as a wall of text. Bulleted lines get a
    /// real bullet in a fixed-width leading column, with the text in a second
    /// column so wrapped lines hang-indent under themselves instead of sliding
    /// back under the bullet.
    @ViewBuilder private func notesLine(_ raw: String) -> some View {
        let mine = Self.isMine(raw, myName: Self.myName)
        let colour = mine ? VF.Color.ink(dark: dark) : VF.Color.body(dark: dark)
        if let item = Self.bulletText(raw) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\u{2022}")
                    .font(VF.Font.body)
                    .foregroundColor(mine ? VF.Color.ink(dark: dark) : VF.Color.faint(dark: dark))
                    .frame(width: VF.Space.md, alignment: .leading)
                Text(rendered(item))
                    .font(VF.Font.body)
                    .lineSpacing(VF.Leading.body)
                    .foregroundColor(colour)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(rendered(raw))
                .font(VF.Font.body)
                .lineSpacing(VF.Leading.body)
                .foregroundColor(colour)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The name to treat as "me", set in Settings. Absent means the promotion
    /// feature is simply off — this is an open-source tool, so hardcoding one
    /// person's name broke it for everybody else.
    static var myName: String? {
        let n = (UserDefaults.standard.string(forKey: "vf_myName") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    /// True when an action item is owned by the person using the app.
    static func isMine(_ line: String, myName: String?) -> Bool {
        guard let me = myName?.lowercased(), !me.isEmpty else { return false }
        return line.lowercased().contains(me)
    }

    /// The text of a markdown list item, or nil when the line is not one.
    static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "\u{2022} "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    struct NotesBlock { let heading: String; let lines: [String] }

    /// Split "**Heading**\n- item\n- item" markdown into blocks so each section
    /// can be typeset rather than dumped as one string.
    static func splitSections(_ notes: String) -> [NotesBlock] {
        var blocks: [NotesBlock] = []
        var heading = ""
        var lines: [String] = []
        for raw in notes.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let isHeading = line.hasPrefix("**") && line.hasSuffix("**") && line.count > 4
            if isHeading {
                if !heading.isEmpty || !lines.isEmpty {
                    blocks.append(NotesBlock(heading: heading, lines: lines))
                }
                heading = String(line.dropFirst(2).dropLast(2))
                lines = []
            } else {
                lines.append(line)
            }
        }
        if !heading.isEmpty || !lines.isEmpty {
            blocks.append(NotesBlock(heading: heading, lines: lines))
        }
        return blocks
    }

    /// A dot only when there is something to say. Every row being green is noise,
    /// not signal.
    @ViewBuilder private func statusDot(_ status: String) -> some View {
        switch status {
        case "processing":
            Circle().fill(VF.Color.attention(dark: dark)).frame(width: 7, height: 7)
        case "error":
            Circle().fill(VF.Color.accent).frame(width: 7, height: 7)
        default:
            Circle().fill(Color.clear).frame(width: 7, height: 7)
        }
    }

    private func subtitle(_ m: ServerClient.MeetingSummary) -> String {
        switch m.status {
        case "processing": return "processing\u{2026}"
        case "error": return m.error.isEmpty ? "failed" : m.error
        default:
            var s = m.ts
            // Counts above this were produced before over-split merging existed
            // and are not trustworthy; showing nothing beats showing a wrong number.
            if m.speakers > 0 && m.speakers <= 8 {
                s += " · \(m.speakers) speaker" + (m.speakers == 1 ? "" : "s")
            }
            return s
        }
    }

    /// Every speaker in this meeting, offered as a chip. Click one to give it a
    /// real name — the server remembers the voice, so the next meeting knows
    /// them without an introduction.
    @ViewBuilder private func speakerBar(_ m: ServerClient.Meeting) -> some View {
        let names = SpeakerText.names(in: m.transcript)
        if !names.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: VF.Space.sm) {
                    Text("Speakers")
                        .font(VF.Font.caption)
                        .foregroundColor(VF.Color.muted(dark: dark))
                        .fixedSize()
                    ForEach(names, id: \.self) { n in
                        Button {
                            promptRenameSpeaker(m.id, current: n)
                        } label: {
                            Text(n)
                                .font(VF.Font.caption)
                                .foregroundColor(n.hasPrefix("Speaker")
                                                 ? VF.Color.muted(dark: dark)
                                                 : VF.Color.ink(dark: dark))
                                .fixedSize()
                                .padding(.horizontal, VF.Space.sm)
                                .padding(.vertical, VF.Space.xs)
                                .background(
                                    Capsule().fill(VF.Color.surfaceHover(dark: dark))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Rename this speaker")
                    }
                }
            }
        }
    }

    private func promptRenameSpeaker(_ meetingID: Int, current: String) {
        let alert = NSAlert()
        alert.messageText = "Who is \(current)?"
        alert.informativeText = "WhisperType will remember this voice and name them automatically in future meetings."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current.hasPrefix("Speaker") ? "" : current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            state.renameSpeaker(meetingID, from: current, to: field.stringValue)
        }
    }

    /// Native rename dialog (a text field in an alert) → server rename.
    private func promptRename(_ m: ServerClient.MeetingSummary) {
        let alert = NSAlert()
        alert.messageText = "Rename meeting"
        alert.informativeText = "Give this meeting a name that's easy to find."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = m.title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            state.rename(m.id, to: field.stringValue)
        }
    }

    /// Confirm before permanently deleting a meeting.
    private func confirmDelete(_ m: ServerClient.MeetingSummary) {
        let alert = NSAlert()
        alert.messageText = "Delete this meeting?"
        alert.informativeText = "“\(m.title.isEmpty ? "Meeting \(m.id)" : m.title)” will be permanently deleted from the server. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            state.delete(m.id)
        }
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
