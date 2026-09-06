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
    @Published var section: MainView.Section = .capture
}

struct MainView: View {
    @ObservedObject var settings: SettingsState
    @ObservedObject var meetings: MeetingsState
    @ObservedObject var nav: MainNav

    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    // Bound so the sidebar always defaults to visible (a fresh window shows it)
    // and the toolbar toggle can bring it back — hiding it can't dead-end.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columns: NavigationSplitViewVisibility = .all

    enum Section: String, CaseIterable, Identifiable {
        case capture = "Capture"
        case inbox = "Inbox"
        case meetings = "Meetings"
        case dictionary = "Dictionary"
        case learning = "Learning"
        case history = "History"
        case microphone = "Microphone"
        case about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .capture: return "waveform"
            case .inbox: return "tray"
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
            List(selection: $nav.section) {
                navigationRows([.capture, .inbox])
                SwiftUI.Section("Library") { navigationRows([.meetings, .history]) }
                SwiftUI.Section("Personalize") { navigationRows([.dictionary, .learning]) }
                SwiftUI.Section("Settings") { navigationRows([.microphone, .about]) }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top) {
                HStack(spacing: VF.Space.sm) {
                    Image(systemName: "waveform").foregroundStyle(VF.Color.accent)
                    Text("WhisperType").font(VF.Font.title)
                    Spacer()
                }.padding(.horizontal, VF.Space.lg).padding(.top, VF.Space.lg).padding(.bottom, VF.Space.sm)
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

        }
    }

    @ViewBuilder private func navigationRows(_ sections: [Section]) -> some View {
        ForEach(sections) { section in
            HStack(spacing: VF.Space.sm) {
                Image(systemName: section.icon).frame(width: 20)
                Text(section.rawValue)
                Spacer(minLength: 0)
                if section == .inbox && !settings.recoveryEntries.isEmpty {
                    Text("\(settings.recoveryEntries.count)").font(VF.Font.caption).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(VF.Color.ink(dark: dark).opacity(0.08), in: Capsule())
                }
            }
            .font(VF.Font.callout).padding(.vertical, VF.Space.xs).tag(section)
            .accessibilityLabel(section.rawValue + (section == .inbox && !settings.recoveryEntries.isEmpty ? ", \(settings.recoveryEntries.count) recordings" : ""))
        }
    }

    @ViewBuilder private var detail: some View {
        switch nav.section {
        case .capture: CaptureHome(state: settings, nav: nav)
        case .inbox: HistoryTab(state: settings, onlyRecovery: true)
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
            Text(settings.serverOK ? "Server connected" : "Server unavailable")
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
            w.setContentSize(NSSize(width: 1080, height: 740))
            w.minSize = NSSize(width: 980, height: 640)
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
