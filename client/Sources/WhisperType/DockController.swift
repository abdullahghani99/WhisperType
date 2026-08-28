import AppKit
import SwiftUI

/// Hosting view for an oversized, mostly-transparent panel.
///
/// The panel is fixed at the dock's maximum size and never resized, so the
/// capsule can animate freely inside it with nothing to clip. The cost is a
/// large transparent margin that would otherwise swallow clicks meant for the
/// app underneath, so anything outside the drawn content is passed through.
final class DockHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let content = fittingSize
        let box = NSRect(x: (bounds.width - content.width) / 2,
                         y: (bounds.height - content.height) / 2,
                         width: content.width, height: content.height)
        return box.contains(point) ? super.hitTest(point) : nil
    }
}
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
    /// Where the dock sits on EACH display. One shared position meant it stayed
    /// on whichever screen was main at launch — which is why it kept turning up
    /// off to one side on a multi-monitor desk.
    private let placement = DockPlacement(store: .standard)
    private var lastScreenID: String?

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
        let key = shapeKey()
        if key != lastShape {
            lastShape = key
            resizeToFit()
        }
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
        let host = DockHostingView(rootView: view)
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
    /// The last shape-affecting state we resized for. `objectWillChange` fires on
    /// every audio level update — dozens per second — and each one used to run a
    /// full SwiftUI layout pass plus a window resize on the main thread. Only the
    /// things that actually change the dock's SIZE should do that.
    private var lastShape: String = ""

    private func shapeKey() -> String {
        "\(state.phase)|\(state.expanded)|\(state.callOffer)|\(state.micName)|\(state.errorText)|\(state.callTitle)|\(Int(state.elapsed))"
    }

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
    /// Keep the panel at a FIXED, generous size and let the dock animate inside
    /// it. Previously the panel was snapped to `fittingSize` on every state
    /// change, which is why size animation had to be disabled: SwiftUI was
    /// animating inside a window that had already jumped to its final bounds, so
    /// the content clipped. Nothing here resizes any more — only the capsule
    /// inside changes width, and it can do so smoothly.
    private func resizeToFit() {
        guard let p = panel, let anchor = anchor else { return }
        let size = Self.panelSize
        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y - Self.verticalPadding)

        // CLAMP TO THE SCREEN. Widening the panel from ~66pt to 620pt moves its
        // origin ~277pt left of the anchor, which pushed it clean off the display
        // near a screen edge — the dock simply vanished. The anchor stays where
        // the human put it; only the window is nudged back into view.
        let screen = Self.activeScreen()
            ?? NSScreen.screens.first { NSPointInRect(anchor, $0.frame) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        let target = NSRect(origin: origin, size: size)
        if p.frame != target { p.setFrame(target, display: true) }
    }

    /// Wide enough for the longest state (the expanded control row) and tall
    /// enough for the shell plus its shadow.
    static let panelSize = NSSize(width: 620, height: 104)
    /// The dock sits centred in the panel, so the anchor accounts for the
    /// transparent margin below it.
    static let verticalPadding: CGFloat = 34


    /// A stable identity for a display, so a remembered position survives sleep,
    /// re-plugging and reordering.
    private static func screenID(_ screen: NSScreen) -> String {
        let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let f = screen.frame
        return "\(n?.intValue ?? 0)-\(Int(f.width))x\(Int(f.height))"
    }

    /// The screen the human is actually working on: the one with the cursor.
    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Move the dock to the active display, restoring where it was parked there.
    func followActiveScreen() {
        guard let screen = Self.activeScreen() else { return }
        let id = Self.screenID(screen)
        guard id != lastScreenID else { return }
        lastScreenID = id
        if let p = placement.position(forScreen: id) {
            anchor = NSPoint(x: p.x, y: p.y)
        } else {
            let f = screen.visibleFrame
            anchor = NSPoint(x: f.midX, y: f.minY + 8)
        }
        resizeToFit()
    }

    private func initialAnchor() -> NSPoint {
        // Positions saved before the panel became a fixed 620pt window were
        // computed against a capsule that hugged its content, so restoring one
        // now lands the dock in the wrong place. Retire those once.
        let migrationKey = "vf_dockAnchorMigratedV2"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            UserDefaults.standard.removeObject(forKey: "vf_dockOrigin")
            UserDefaults.standard.removeObject(forKey: "vf_dockPositions")
            UserDefaults.standard.set(true, forKey: migrationKey)
        }
        if let saved = Self.loadSavedOrigin() { return saved }
        let f = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSPoint(x: f.midX, y: f.minY + 12)   // centred, just clear of the macOS Dock
    }

    /// User dragged the panel — recompute the anchor from its new bottom-center.
    private func userMoved() {
        guard let p = panel else { return }
        let a = NSPoint(x: p.frame.midX, y: p.frame.minY)
        anchor = a
        if let screen = Self.activeScreen() {
            let id = Self.screenID(screen)
            lastScreenID = id
            placement.remember(x: Double(a.x), y: Double(a.y), forScreen: id)
        }
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
