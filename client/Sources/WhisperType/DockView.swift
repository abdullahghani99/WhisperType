import SwiftUI
import WhisperTypeKit

// MARK: - Palette
//
// Verbatim Uliverse dock palette. Kept private to this file so DockView is
// self-contained and drop-in — no shared design-system dependency yet.

private extension Color {
    static let vfSurfaceTop = Color(red: 0x28 / 255, green: 0x24 / 255, blue: 0x20 / 255)
    static let vfSurfaceBottom = Color(red: 0x1A / 255, green: 0x17 / 255, blue: 0x14 / 255)
    static let vfWarmWhite = Color(red: 0xFA / 255, green: 0xFA / 255, blue: 0xF9 / 255)
    static let vfMuted = Color(red: 0x92 / 255, green: 0x8A / 255, blue: 0x81 / 255)
    static let vfAccent = Color(red: 0xE7 / 255, green: 0x00 / 255, blue: 0x0B / 255)
    static let vfGreen = Color(red: 0x5C / 255, green: 0xB8 / 255, blue: 0x7A / 255)
    static let vfAmber = Color(red: 0xE0 / 255, green: 0xA6 / 255, blue: 0x3C / 255)
}

/// Fixed sine-shaped envelope for the 24-bar waveform: tall in the middle,
/// tapering at the edges, so the waveform reads as "a waveform" even at
/// silence — `state.level` only modulates amplitude on top of this shape,
/// it never changes which bars exist.
private let vfWaveformEnvelope: [CGFloat] = (0 ..< 24).map { i in
    let t = Double(i + 1) / 25.0
    return CGFloat(sin(t * .pi))
}

/// The two center bars carry the accent tint — one of the only three places
/// red appears in the dock (record dot, waveform center, active-mic check).
private let vfWaveformAccentIndices: Set<Int> = [11, 12]

private let vfWaveformBarCount = vfWaveformEnvelope.count
private let vfWaveformBarMaxHeight: CGFloat = 22

// MARK: - DockView

/// The floating dock: a warm-black capsule that is the visual centerpiece of
/// the app. Idle / listening / transcribing / error states live inside the
/// same capsule; hovering reveals a secondary control row (mic, mode,
/// meeting, settings) below it.
public struct DockView: View {
    @ObservedObject var state: DockState

    let onToggleRecord: () -> Void
    let onPickMic: (String) -> Void
    let onToggleMode: () -> Void
    let onMeeting: () -> Void
    let onSettings: () -> Void
    let micDevices: () -> [(uid: String, name: String)]

    @State private var transcribingPulse = false
    /// Preview/testability only: force the hover control row visible for
    /// screenshot verification. Default false — no runtime behavior change.
    let forceControls: Bool

    public init(
        state: DockState,
        forceControls: Bool = false,
        onToggleRecord: @escaping () -> Void,
        onPickMic: @escaping (String) -> Void,
        onToggleMode: @escaping () -> Void,
        onMeeting: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        micDevices: @escaping () -> [(uid: String, name: String)]
    ) {
        self.state = state
        self.forceControls = forceControls
        self.onToggleRecord = onToggleRecord
        self.onPickMic = onPickMic
        self.onToggleMode = onToggleMode
        self.onMeeting = onMeeting
        self.onSettings = onSettings
        self.micDevices = micDevices
    }

    public var body: some View {
        Group {
            if state.phase == .idle {
                // Minimal: at rest a tiny mic pill; one CLICK reveals ONLY the
                // control bar. Click the bar's empty space to collapse.
                if state.expanded || forceControls {
                    controlRow.onTapGesture { state.expanded = false }
                } else {
                    restPill
                }
            } else {
                mainCapsule   // listening / transcribing / done / error
            }
        }
        .padding(16)   // room for the capsule's drop shadow so the panel can hug it
        .fixedSize()   // report an exact intrinsic size so the panel sizes to content
        // No size animation: the panel must match the content exactly, or a
        // mid-animation size mismatch clips the dock. Expansion is instant.
        .onChange(of: state.phase) { newPhase in
            if newPhase != .idle { state.expanded = false }
        }
    }

    /// The single resting state: JUST the mic glyph — no circle chrome. Bigger and
    /// cleaner, floating over your work. Two soft shadows keep it legible on any
    /// background (dark or light). It stays warm-white when all's well and tints
    /// amber only if the server is unreachable — the one status worth a glance.
    /// Click to reveal controls; auto-expands to the waveform while recording.
    private var restPill: some View {
        ZStack {
            // Subtle frosted "pebble": legible over ANY background (unlike a bare
            // glyph), but light — not the heavy gradient circle. Warm-black,
            // semi-transparent, thin hairline, soft shadow.
            Circle()
                .fill(Color(red: 0x1A/255, green: 0x17/255, blue: 0x14/255).opacity(0.82))
                .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 5, x: 0, y: 2)
                .frame(width: 30, height: 30)
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(state.serverOK ? .vfWarmWhite : .vfAmber)
        }
        .frame(width: 34, height: 34)
        .contentShape(Circle())
        .onTapGesture { state.expanded = true }
    }

    // MARK: Main capsule

    private var mainCapsule: some View {
        phaseContent
            .padding(.horizontal, 18)
            .frame(height: 46)
            .fixedSize(horizontal: true, vertical: false)   // hug content — idle stays compact
            .background(dockSurface)
            .contentShape(Capsule())
            .onTapGesture {
                // Click toggles the controls (mic/mode/settings). Recording is
                // driven by the ⌥ hotkey, which auto-expands the waveform.
                if state.phase == .idle { state.expanded.toggle() }
            }
    }

    private var dockSurface: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [.vfSurfaceTop, .vfSurfaceBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch state.phase {
        case .idle, .done:
            idleContent
        case .listening:
            listeningContent
        case .transcribing:
            transcribingContent
        case .error:
            errorContent
        }
    }

    // MARK: Idle

    private var idleContent: some View {
        HStack(spacing: 9) {
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.vfWarmWhite)
            Text("Hold \u{2325} to talk")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.vfWarmWhite.opacity(0.9))
            Circle()
                .fill(state.serverOK ? Color.vfGreen : Color.vfAmber)
                .frame(width: 7, height: 7)
                .padding(.leading, 2)
        }
    }

    // MARK: Listening

    private var listeningContent: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.vfAccent)
                .frame(width: 10, height: 10)

            waveform

            Text(elapsedString)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(.vfWarmWhite)
        }
    }

    private var waveform: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< vfWaveformBarCount, id: \.self) { i in
                Capsule()
                    .fill(vfWaveformAccentIndices.contains(i)
                          ? Color.vfAccent
                          : Color.vfWarmWhite.opacity(0.85))
                    .frame(width: 2.5, height: barHeight(at: i))
            }
        }
        .frame(height: vfWaveformBarMaxHeight)
    }

    private func barHeight(at index: Int) -> CGFloat {
        let scale = 0.25 + 0.75 * CGFloat(state.level)
        return max(2, vfWaveformEnvelope[index] * vfWaveformBarMaxHeight * scale)
    }

    private var elapsedString: String {
        let total = Int(state.elapsed.rounded(.down))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: Transcribing

    private var transcribingContent: some View {
        Text("Polishing\u{2026}")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.vfMuted)
            .opacity(transcribingPulse ? 0.35 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    transcribingPulse = true
                }
            }
    }

    // MARK: Error

    private var errorContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.vfAccent)
            Text(state.errorText.isEmpty ? "Something went wrong" : state.errorText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.vfAccent)
                .lineLimit(1)
        }
    }

    // MARK: Hover control row

    private var controlRow: some View {
        HStack(spacing: 12) {
            micChip

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 18)

            modeSegment

            Button(action: onMeeting) {
                Image(systemName: "record.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.vfWarmWhite)   // accent reserved for LIVE cues only
            }
            .buttonStyle(.plain)

            Button(action: onSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.vfWarmWhite)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .fixedSize(horizontal: true, vertical: false)   // hug content — no label truncation
        .background(dockSurface)
    }

    private var micChip: some View {
        Menu {
            ForEach(micDevices(), id: \.uid) { device in
                Button {
                    onPickMic(device.uid)
                } label: {
                    HStack {
                        Text(device.name)
                        if device.name == state.micName {
                            Image(systemName: "checkmark").foregroundColor(.vfAccent)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.vfWarmWhite)
                Text(state.micName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.vfWarmWhite)
                    .lineLimit(1)
                    .frame(maxWidth: 130, alignment: .leading)   // keep the bar compact
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.vfMuted)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var modeSegment: some View {
        HStack(spacing: 2) {
            modeButton(title: "Dictation", isActive: state.mode == .dictation)
            modeButton(title: "Prompt", isActive: state.mode == .prompt)
        }
        .padding(3)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.25))
        )
    }

    private func modeButton(title: String, isActive: Bool) -> some View {
        Button {
            if !isActive { onToggleMode() }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isActive ? .vfSurfaceBottom : .vfMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isActive ? Color.vfWarmWhite : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}
