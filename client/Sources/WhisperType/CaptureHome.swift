import SwiftUI
import WhisperTypeKit

struct CaptureHome: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var nav: MainNav
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var prompt: Bool { state.captureMode == .prompt }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VF.Space.xxl) {
                VStack(alignment: .leading, spacing: VF.Space.sm) {
                    Text("Capture").font(VF.Font.display).tracking(VF.Tracking.display)
                    Text("Speak a dictation, shape a prompt, or keep a meeting.")
                        .font(VF.Font.body).foregroundStyle(VF.Color.muted(dark: dark))
                }
                VStack(alignment: .leading, spacing: VF.Space.xl) {
                    HStack {
                        Picker("Recording mode", selection: $state.captureMode) {
                            Text("Dictation").tag(DockState.Mode.dictation)
                            Text("Prompt").tag(DockState.Mode.prompt)
                        }.pickerStyle(.segmented).labelsHidden().fixedSize()
                            .disabled(state.capturing || state.meetingCapturing)
                        Spacer()
                        Button { nav.section = .microphone } label: {
                            Label(state.activeMicName, systemImage: "mic").lineLimit(1)
                        }.buttonStyle(.plain).font(VF.Font.callout)
                            .foregroundStyle(VF.Color.muted(dark: dark)).help("Choose microphone and check permissions")
                    }
                    VStack(alignment: .leading, spacing: VF.Space.md) {
                        Text(state.capturing ? state.captureStatus : (prompt ? "A clearer request starts here." : "Ready to listen."))
                            .font(VF.Font.title).tracking(VF.Tracking.title)
                        Text(prompt ? "Say what you need. Review three versions, edit the wording, then choose where it goes." : "Speak naturally. Your words become text you can review or use in any app.")
                            .font(VF.Font.body).foregroundStyle(VF.Color.muted(dark: dark))
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 500, alignment: .leading)
                    }
                    HStack(spacing: VF.Space.md) {
                        Button { state.onToggleRecording?() } label: {
                            Label(state.capturing ? "Stop recording" : (prompt ? "Record prompt" : "Record dictation"), systemImage: state.capturing ? "stop.fill" : "mic.fill")
                        }.buttonStyle(VFActionStyle(.primary)).disabled(state.meetingCapturing)
                        Text("Hold Right Option ⌥ in another app")
                            .font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: dark))
                    }
                    Text("Record here to review in Inbox. Use the shortcut in another app to place your dictation there.")
                        .font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: dark))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, VF.Space.sm)

                Divider()
                HStack(alignment: .center, spacing: VF.Space.xl) {
                    VStack(alignment: .leading, spacing: VF.Space.sm) {
                        Label(state.meetingCapturing ? "Meeting in progress" : "Record a meeting", systemImage: "person.wave.2")
                            .font(VF.Font.heading)
                        Text("Capture the conversation and return to a transcript, decisions, and next steps.")
                            .font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(state.meetingCapturing ? "Finish meeting" : "Start meeting") { state.onToggleMeeting?() }
                        .buttonStyle(VFActionStyle()).disabled(state.capturing)
                }
                HStack(spacing: 14) {
                    Button("Import a recording…") { state.onImportRecording?() }.buttonStyle(VFActionStyle()).disabled(state.importing)
                    if !state.importStatus.isEmpty { Text(state.importStatus).font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: dark)).lineLimit(2) }
                    Spacer(minLength: 0)
                    if state.importing { Button("Cancel import") { state.onCancelImport?() }.buttonStyle(VFActionStyle()) }
                }
                Divider()
                VStack(alignment: .leading, spacing: VF.Space.lg) {
                    HStack {
                        Text("In your inbox").font(VF.Font.heading)
                        Spacer()
                        Button { nav.section = .inbox } label: { Label("Open Inbox", systemImage: "arrow.right") }
                            .buttonStyle(.plain).font(VF.Font.callout)
                    }
                    if state.recoveryEntries.isEmpty {
                        Text("All caught up. Results that need your attention will appear here.")
                            .font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark))
                    } else {
                        ForEach(Array(state.recoveryEntries.prefix(2))) { entry in
                            Button { nav.section = .inbox } label: {
                                HStack(alignment: .top, spacing: VF.Space.md) {
                                    Image(systemName: entry.text.isEmpty ? "arrow.clockwise" : "text.alignleft")
                                        .frame(width: 18).padding(.top, 2).foregroundStyle(VF.Color.muted(dark: dark))
                                    VStack(alignment: .leading, spacing: VF.Space.xs) {
                                        HStack {
                                            Text(entry.kind.capitalized).font(VF.Font.callout).fontWeight(.medium)
                                            Text(entry.created.formatted(date: .omitted, time: .shortened))
                                                .font(VF.Font.caption).foregroundStyle(VF.Color.muted(dark: dark))
                                        }
                                        Text(entry.text.isEmpty ? "Audio saved · ready to retry" : entry.text).lineLimit(1)
                                            .font(VF.Font.callout).foregroundStyle(VF.Color.muted(dark: dark))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).padding(.top, 4)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if state.microphonePermission != "Allowed" || !state.serverOK {
                    HStack(spacing: VF.Space.sm) {
                        Image(systemName: "exclamationmark.circle")
                        Text(state.microphonePermission != "Allowed" ? "Allow microphone access before recording." : "Server unavailable. Saved audio can be retried from Inbox.")
                            .font(VF.Font.callout)
                        Spacer()
                        Button("Check readiness") { nav.section = .microphone }.buttonStyle(VFActionStyle())
                    }.padding(VF.Space.lg).background(VF.Color.surfaceHover(dark: dark), in: RoundedRectangle(cornerRadius: VF.Radius.sm))
                }
            }
            .foregroundStyle(VF.Color.ink(dark: dark))
            .padding(VF.Space.xxxl).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onAppear { state.onCheckPermissions?(); state.reloadRecovery() }
        .onReceive(NotificationCenter.default.publisher(for: .vfRecordingsChanged)) { _ in state.reloadRecovery() }
    }
}
