import AppKit
import SwiftUI
import Combine
import WhisperTypeKit

/// Hosts `DockView` in a floating, non-activating `NSPanel` that sits ABOVE
/// every other window — including a Screen Sharing / VNC session window.
/// This is what makes the dock usable while the "active" surface on screen
/// is actually a remote desktop: the panel is never part of that remote
/// window, it floats over the whole local display independent of Spaces.
final class DockController {
    let state = DockState()
    private var panel: NSPanel?
    private var hosting: NSHostingView<DockView>?
    private var cancellable: AnyCancellable?
    /// The fixed bottom-center anchor the dock grows/shrinks around, so expanding
    /// from the tiny idle pill to the full capsule stays centered in place.
    private var anchor: NSPoint?

    var onToggleRecord: () -> Void = {}
    var onPickMic: (String) -> Void = { _ in }
    var onToggleMode: () -> Void = {}
    var onMeeting: () -> Void = {}
    var onSettings: () -> Void = {}
    var micDevices: () -> [(uid: String, name: String)] = { [] }

    private static let originDefaultsKey = "vf_dock_origin"

    func show() {
        if panel == nil { panel = makePanel() }
        if anchor == nil { anchor = initialAnchor() }
        resizeToFit()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    // MARK: - Panel construction

    private func makePanel() -> NSPanel {
        let view = DockView(
            state: state,
            onToggleRecord: { [weak self] in self?.onToggleRecord() },
            onPickMic: { [weak self] uid in self?.onPickMic(uid) },
            onToggleMode: { [weak self] in self?.onToggleMode() },
            onMeeting: { [weak self] in self?.onMeeting() },
            onSettings: { [weak self] in self?.onSettings() },
            micDevices: { [weak self] in self?.micDevices() ?? [] }
        )
        let host = NSHostingView(rootView: view)
        if #available(macOS 13.0, *) { host.sizingOptions = [.intrinsicContentSize] }
        hosting = host

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.contentView = host
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false

        // React to state changes: re-fit the panel (only when the SIZE actually
        // changes — not on every audio-level tick) and run the elapsed timer.
        cancellable = state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.stateChanged() }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main
        ) { [weak self] _ in self?.userMoved() }

        return p
    }

    // MARK: - Sizing / positioning

    private var elapsedTimer: Timer?
    private var errorClearTimer: Timer?

    /// Runs on every published change. Cheap and idempotent: manage the elapsed
    /// timer by phase, auto-clear a stuck error, and re-fit when size changed.
    private func stateChanged() {
        // Elapsed timer: tick once per second while listening.
        if state.phase == .listening {
            if elapsedTimer == nil {
                elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.state.elapsed += 1
                }
            }
        } else {
            elapsedTimer?.invalidate(); elapsedTimer = nil
        }
        // Auto-clear the error state so the dock never gets STUCK on "No audio".
        if state.phase == .error {
            if errorClearTimer == nil {
                errorClearTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                    self?.errorClearTimer = nil
                    if self?.state.phase == .error { self?.state.returnToIdle() }
                }
            }
        } else {
            errorClearTimer?.invalidate(); errorClearTimer = nil
        }
        resizeToFit()
    }

    /// Size the panel to the dock's current intrinsic content, anchored so the
    /// bottom-center stays put as it grows/shrinks. No-op when the size is
    /// unchanged, so rapid level updates during recording don't churn setFrame.
    private func resizeToFit() {
        guard let p = panel, let host = hosting, let anchor = anchor else { return }
        host.layoutSubtreeIfNeeded()          // ensure SwiftUI has laid out the NEW state
        let size = host.fittingSize            // ...so this is the real size, not stale (was clipping)
        guard size.width > 1, size.height > 1 else { return }
        if abs(p.frame.width - size.width) < 0.5, abs(p.frame.height - size.height) < 0.5 { return }
        let origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func initialAnchor() -> NSPoint {
        if let saved = Self.loadSavedOrigin() { return saved }
        let f = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSPoint(x: f.midX, y: f.minY + 8)   // bottom-center, close to the edge
    }

    /// User dragged the panel — recompute the anchor from its new bottom-center.
    private func userMoved() {
        guard let p = panel else { return }
        anchor = NSPoint(x: p.frame.midX, y: p.frame.minY)
        UserDefaults.standard.set(NSStringFromPoint(anchor!), forKey: Self.originDefaultsKey)
    }

    private static func loadSavedOrigin() -> NSPoint? {
        guard let raw = UserDefaults.standard.string(forKey: originDefaultsKey), !raw.isEmpty else {
            return nil
        }
        let p = NSPointFromString(raw)
        // NSPointFromString returns .zero for an unparsable string; treat
        // that as "no saved origin" rather than pinning the dock at (0, 0).
        guard p != .zero else { return nil }
        return p
    }
}
