import SwiftUI
import AppKit

/// Visual state shared between the app and the floating pill UI.
enum OverlayMode: Equatable {
    case hidden
    case listening
    case transcribing
    case message(String)
}

final class OverlayState: ObservableObject {
    @Published var mode: OverlayMode = .hidden
    @Published var levels: [Float] = Array(repeating: 0.04, count: 28)

    /// Push a new audio level, scrolling the waveform left.
    func pushLevel(_ v: Float) {
        var l = levels
        l.removeFirst()
        l.append(max(0.04, v))
        levels = l
    }
}

/// Uliverse palette (warm black / warm off-white / red accent used sparingly).
private extension Color {
    static let vfInk = Color(red: 0x1A/255, green: 0x17/255, blue: 0x14/255)
    static let vfPaper = Color(red: 0xFA/255, green: 0xFA/255, blue: 0xF9/255)
    static let vfAccent = Color(red: 0xE7/255, green: 0x00/255, blue: 0x0B/255)
}

/// The floating pill, à la Wispr — bottom-centre, waveform while listening.
struct OverlayView: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        // Fill the panel and centre the pill inside it, so it's truly centred
        // on screen horizontally (the panel itself is screen-centred).
        pill.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var pill: some View {
        HStack(spacing: 12) {
            switch state.mode {
            case .listening:
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.vfAccent)
                RecordingDot()
                Waveform(levels: state.levels)
                    .frame(width: 170, height: 24)
                Text("Listening")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.vfPaper.opacity(0.85))
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.vfPaper)
                Text("Transcribing…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.vfPaper.opacity(0.85))
            case .message(let m):
                Image(systemName: "info.circle")
                    .foregroundStyle(Color.vfAccent)
                Text(m)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.vfPaper.opacity(0.9))
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .leading)
            case .hidden:
                EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            Capsule(style: .continuous)
                .fill(Color.vfInk.opacity(0.96))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        )
        .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .fixedSize()
    }
}

private struct RecordingDot: View {
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(Color.vfAccent)
            .frame(width: 10, height: 10)
            .opacity(pulse ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

private struct Waveform: View {
    let levels: [Float]
    var body: some View {
        GeometryReader { geo in
            let n = levels.count
            let barW = (geo.size.width - CGFloat(n - 1) * 3) / CGFloat(n)
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<n, id: \.self) { i in
                    Capsule()
                        .fill(Color.vfPaper.opacity(0.9))
                        .frame(width: barW,
                               height: max(3, CGFloat(levels[i]) * geo.size.height))
                        .animation(.linear(duration: 0.08), value: levels[i])
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

/// Hosts OverlayView in a borderless, click-through floating panel pinned to the
/// bottom-centre of the active screen.
final class OverlayController {
    let state = OverlayState()
    private var panel: NSPanel?

    func ensurePanel() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: OverlayView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 56)

        let p = NSPanel(contentRect: hosting.frame,
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.contentView = hosting
        panel = p
    }

    func show(_ mode: OverlayMode) {
        DispatchQueue.main.async {
            self.ensurePanel()
            self.state.mode = mode
            guard let panel = self.panel else { return }
            if let screen = NSScreen.main {
                let size = panel.frame.size
                let x = screen.frame.midX - size.width / 2   // horizontally centred
                let y = screen.frame.minY + 110              // near the bottom (as before)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            panel.orderFrontRegardless()
        }
    }

    func hide(after seconds: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            self.state.mode = .hidden
            self.panel?.orderOut(nil)
        }
    }
}
