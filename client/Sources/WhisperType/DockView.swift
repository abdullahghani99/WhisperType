import SwiftUI
import WhisperTypeKit

/// The floating pill shares one shell across every state. Controls stay native
/// buttons; native material preserves context while accessibility can make it opaque.
public struct DockView: View {
    @ObservedObject var state: DockState
    let onToggleRecord: () -> Void
    let onPickMic: (String) -> Void
    let onToggleMode: () -> Void
    let onMeeting: () -> Void
    let onAcceptCall: () -> Void
    let onSettings: () -> Void
    let onRecovery: () -> Void
    let micDevices: () -> [(uid: String, name: String)]
    let forceControls: Bool
    let onHoverChanged: (Bool) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    private let ink = VF.Color.ink(dark: true)
    private let muted = VF.Color.muted(dark: true)
    private var controlsVisible: Bool { state.expanded || forceControls }
    private var compact: Bool { state.canCollapsePresentation && !controlsVisible }

    public init(state: DockState, forceControls: Bool = false,
                onToggleRecord: @escaping () -> Void, onPickMic: @escaping (String) -> Void,
                onToggleMode: @escaping () -> Void, onMeeting: @escaping () -> Void,
                onSettings: @escaping () -> Void, micDevices: @escaping () -> [(uid: String, name: String)],
                onRecovery: @escaping () -> Void = {}, onHoverChanged: @escaping (Bool) -> Void = { _ in },
                onAcceptCall: @escaping () -> Void = {}) {
        self.state = state; self.forceControls = forceControls; self.onHoverChanged = onHoverChanged
        self.onToggleRecord = onToggleRecord; self.onPickMic = onPickMic
        self.onToggleMode = onToggleMode; self.onMeeting = onMeeting; self.onAcceptCall = onAcceptCall
        self.onSettings = onSettings; self.micDevices = micDevices; self.onRecovery = onRecovery
    }

    public var body: some View {
        content
            .font(VF.Font.callout).foregroundStyle(ink)
            .padding(.horizontal, compact ? 8 : 14)
            .padding(.vertical, compact ? 4 : 6).frame(minHeight: compact ? 24 : 40)
            .background {
                ZStack {
                    if !compact || state.phase != .idle || reduceTransparency || contrast == .increased {
                        VF.Color.surface(dark: true)
                    } else {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.ultraThinMaterial).overlay(Color.black.opacity(0.32))
                    }
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(ink.opacity(contrast == .increased ? 0.6 : 0.18), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onTapGesture { state.collapsePresentation() }
                .shadow(color: Color.black.opacity(compact ? 0.14 : 0.22), radius: compact ? 5 : 10, x: 0, y: 3)
            }
            .fixedSize()
            .padding(16)
            .preferredColorScheme(.dark)
            .onHover { hovering = $0; onHoverChanged($0) }
            .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 1), value: state.phase)
            .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 1), value: state.expanded)
            .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 1), value: state.meetingRecording)
            .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 1), value: state.callOffer)
            .onExitCommand { state.collapsePresentation() }
    }

    @ViewBuilder private var content: some View {
        if compact { restContent }
        else if state.meetingRecording && state.phase != .listening && state.phase != .starting {
            meetingContent
        } else if state.showsCallOffer {
            callOfferContent
        } else {
            switch state.phase {
            case .idle:
                if controlsVisible { controls }
                else { restContent }
            case .starting:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).accessibilityLabel("Starting microphone")
                    Text("Starting microphone…")
                    textAction("Cancel", action: onToggleRecord)
                }
            case .listening:
                HStack(spacing: 12) {
                    Circle().fill(VF.Color.accent).frame(width: 8, height: 8).accessibilityHidden(true)
                    waveform.accessibilityHidden(true)
                    Text(elapsed(state.elapsed)).monospacedDigit().frame(minWidth: 36)
                        .accessibilityLabel("Recording, \(Int(state.elapsed)) seconds")
                    iconAction("stop.fill", label: state.mode == .prompt ? "Stop prompt recording" : "Stop dictation", action: onToggleRecord)
                }
            case .transcribing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).accessibilityLabel("Processing recording")
                    Text(state.mode == .prompt ? "Preparing prompt…" : "Transcribing…")
                    textAction("Inbox", action: onRecovery)
                }
            case .ready:
                HStack(spacing: 10) {
                    Image(systemName: "tray.full").accessibilityHidden(true)
                    Text("Result ready")
                    textAction("Review", action: onRecovery)
                    iconAction("xmark", label: "Dismiss status; result remains in Inbox") { state.returnToIdle() }
                }
            case .done:
                HStack(spacing: 8) {
                    Image(systemName: state.placementUnverified ? "paperplane" : "checkmark.circle.fill").foregroundStyle(VF.Color.healthy(dark: true)).accessibilityHidden(true)
                    Text(state.placementUnverified ? "Sent" : state.lastWordCount > 0 ? "\(state.lastWordCount) words sent" : "Text sent")
                }.accessibilityElement(children: .combine)
            case .error:
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(VF.Color.attention(dark: true)).accessibilityHidden(true)
                    Text(state.errorText.isEmpty ? "Recording needs attention" : state.errorText)
                        .lineLimit(2).frame(maxWidth: 280, alignment: .leading)
                        .help(state.errorText)
                    textAction("Inbox", action: onRecovery)
                    iconAction("xmark", label: "Dismiss status; saved recordings remain in Inbox") { state.returnToIdle() }
                }
            }
        }
    }

    private var restContent: some View {
        Button { state.expanded = true } label: {
            HStack(spacing: 6) {
                Image(systemName: state.phase == .error ? "exclamationmark.circle.fill" : state.phase == .ready ? "tray.full.fill" : state.mode == .prompt ? "text.bubble" : "mic.fill")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: state.serverOK ? "chevron.up" : "exclamationmark.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(state.serverOK ? ink.opacity(hovering ? 0.9 : 0.5) : VF.Color.attention(dark: true))
            }.frame(width: 28, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.phase == .ready ? "Result ready in Inbox; expand status" : state.phase == .error ? "\(state.errorText); expand status" : "Open recording controls, \(state.mode == .prompt ? "Prompt" : "Dictation") mode\(state.serverOK ? "" : ", server unavailable")")
        .help("\(state.mode == .prompt ? "Prompt" : "Dictation") · click for controls, or hold Right Option to record")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: onToggleRecord) {
                Label("Record", systemImage: "mic.fill").font(VF.Font.caption)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(ink, in: Capsule()).foregroundStyle(VF.Color.canvas(dark: true))
            }.buttonStyle(.plain).accessibilityLabel("Record \(state.mode == .prompt ? "prompt" : "dictation")")
            micMenu
            Rectangle().fill(ink.opacity(0.16)).frame(width: 1, height: 18).padding(.horizontal, 2)
            modeControls
            iconAction("person.wave.2", label: "Record meeting", action: onMeeting)
            iconAction("slider.horizontal.3", label: "Open WhisperType settings", action: onSettings)
            iconAction("chevron.down", label: "Collapse recording controls") { state.expanded = false }
        }
    }

    private var micMenu: some View {
        Menu {
            Button("Follow system default") { onPickMic("") }
            Divider()
            ForEach(micDevices(), id: \.uid) { device in
                Button(device.name) { onPickMic(device.uid) }
            }
            Divider()
            Text("Active: \(state.micName)")
        } label: {
            Label {
                Text(state.micName).lineLimit(1).truncationMode(.middle).frame(maxWidth: 115, alignment: .leading)
            } icon: { Image(systemName: "mic") }
            .font(VF.Font.caption).frame(height: 28)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Microphone, \(state.micName)").help("Active microphone: \(state.micName)")
    }

    private var modeControls: some View {
        HStack(spacing: 2) {
            modeButton("Dictation", active: state.mode == .dictation)
            modeButton("Prompt", active: state.mode == .prompt)
        }.padding(2).background(Color.black.opacity(0.22), in: Capsule())
    }
    private func modeButton(_ title: String, active: Bool) -> some View {
        Button { if !active { onToggleMode() } } label: {
            Text(title).font(VF.Font.caption).padding(.horizontal, 9).frame(height: 24)
                .foregroundStyle(active ? VF.Color.canvas(dark: true) : ink.opacity(0.78))
                .background(active ? ink : Color.clear, in: Capsule())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(title) mode").accessibilityValue(active ? "Selected" : "Not selected")
    }

    private var meetingContent: some View {
        HStack(spacing: 10) {
            Image(systemName: state.meetingMicTrouble ? "exclamationmark.circle.fill" : "record.circle.fill")
                .foregroundStyle(state.meetingMicTrouble ? VF.Color.attention(dark: true) : VF.Color.accent).accessibilityHidden(true)
            Text(state.meetingMicTrouble ? "Microphone needs attention" : "Meeting")
            Text(elapsed(state.meetingElapsed)).monospacedDigit().frame(minWidth: 40)
            if state.meetingMicTrouble { iconAction("slider.horizontal.3", label: "Check microphone", action: onSettings) }
            iconAction("stop.fill", label: "Finish meeting recording", action: onMeeting)
        }.help(state.meetingMicTrouble ? "System audio is still recording. Check microphone input." : "Recording meeting · \(state.micName)")
    }
    private var callOfferContent: some View {
        HStack(spacing: 10) {
            if let data = state.callIconPNG, let icon = NSImage(data: data) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18).accessibilityHidden(true)
            } else { Image(systemName: "phone").accessibilityHidden(true) }
            Text(state.callTitle).lineLimit(1).frame(maxWidth: 240)
            textAction("Record", action: onAcceptCall)
            iconAction("xmark", label: "Dismiss meeting offer") { state.callOffer = false }
        }
    }
    private var waveform: some View {
        HStack(spacing: 2) {
            ForEach(0..<24, id: \.self) { index in
                let level = reduceMotion ? state.level : state.levels[index]
                Capsule().fill(ink.opacity(0.88)).frame(width: 2, height: max(2, CGFloat(level) * 22))
            }
        }.frame(width: 94, height: 24)
    }
    private func elapsed(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
    private func textAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(VF.Font.caption).padding(.horizontal, 10).frame(height: 28)
                .background(ink.opacity(0.12), in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain)
    }
    private func iconAction(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28).contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(label).help(label)
    }
}
