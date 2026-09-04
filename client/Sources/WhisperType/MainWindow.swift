import SwiftUI
import AppKit
import WhisperTypeKit

/// The one unified WhisperType window — a light sidebar app that replaces the
/// scattered Settings/Meetings windows. Sections reuse the existing views, so
/// there's a single cohesive home for everything: meetings, dictation history,
/// dictionary, microphone, about.
/// Shared, observable selection so the menu bar can open the window straight to
/// a section (e.g. "Settings & Dictionary…" → Dictionary).
final class MainNav: ObservableObject {
    @Published var section: MainView.Section = .meetings
}

struct MainView: View {
    @ObservedObject var settings: SettingsState
    @ObservedObject var meetings: MeetingsState
    @ObservedObject var nav: MainNav

    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    // Bound so the sidebar always defaults to visible (a fresh window shows it)
    // and the toolbar toggle can bring it back — hiding it can't dead-end.
    @State private var columns: NavigationSplitViewVisibility = .all

    enum Section: String, CaseIterable, Identifiable {
        case meetings = "Meetings"
        case dictionary = "Dictionary"
        case learning = "Learning"
        case history = "History"
        case microphone = "Microphone"
        case about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .meetings: return "person.wave.2"
            case .dictionary: return "character.book.closed"
            case .learning: return "sparkles"
            case .history: return "clock.arrow.circlepath"
            case .microphone: return "mic"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(Section.allCases, selection: $nav.section) { s in
                Label(s.rawValue, systemImage: s.icon)
                    .font(VF.Font.body)
                    .foregroundColor(VF.Color.ink(dark: dark))
                    .tag(s)
            }
            .scrollContentBackground(.hidden)
            .background(VF.Color.surfaceHover(dark: dark))
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { statusBar }
        } detail: {
            detail
                .frame(minWidth: 560, minHeight: 520)
                .background(VF.Color.canvas(dark: dark))
                .navigationTitle(nav.section.rawValue)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            withAnimation { columns = (columns == .detailOnly) ? .all : .detailOnly }
                        } label: {
                            Image(systemName: "sidebar.leading")
                        }
                        .help("Show or hide the sidebar")
                    }
                }
        }
    }

    @ViewBuilder private var detail: some View {
        switch nav.section {
        case .meetings: MeetingsView(state: meetings)
        case .dictionary: DictionaryTab(state: settings)
        case .learning: LearningTab(state: settings)
        case .history: HistoryTab(state: settings)
        case .microphone: MicTab(state: settings)
        case .about: AboutTab()
        }
    }

    /// Compact server-health footer in the sidebar.
    private var statusBar: some View {
        HStack(spacing: VF.Space.sm) {
            Circle()
                .fill(settings.serverOK ? VF.Color.healthy(dark: dark) : VF.Color.attention(dark: dark))
                .frame(width: 7, height: 7)
            Text(settings.serverOK ? "Server connected" : "Connecting\u{2026}")
                .font(VF.Font.caption)
                .foregroundColor(VF.Color.muted(dark: dark))
            Spacer()
        }
        .padding(.horizontal, VF.Space.md)
        .padding(.vertical, VF.Space.sm)
    }
}

/// Hosts MainView in a single real window opened from the menu bar.
final class MainWindowController {
    private var window: NSWindow?
    let settings = SettingsState()
    let meetings = MeetingsState()
    let nav = MainNav()

    func show(client: ServerClient, section: MainView.Section? = nil) {
        settings.client = client
        meetings.client = client
        if let section = section { nav.section = section }
        if window == nil {
            let hosting = NSHostingController(rootView: MainView(settings: settings, meetings: meetings, nav: nav))
            let w = NSWindow(contentViewController: hosting)
            w.title = "WhisperType"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: 900, height: 600))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        settings.reload(); settings.loadMics(); settings.loadSuggestions(); settings.pingServer()
        meetings.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
