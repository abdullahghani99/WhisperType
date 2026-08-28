import AppKit
import ApplicationServices
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
        startDockWatch()
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
    /// Polls the macOS Dock so our pill can ride above it. Cheap (4Hz, one
    /// window-list read) and it is the difference between a dock that sits in a
    /// fixed spot and one that feels aware of its surroundings.
    private var dockWatchTimer: Timer?
    private var lastDockTop: CGFloat = -1
    /// The Dock's icon list, held across ticks. Re-reading its position costs
    /// 0.089ms; re-finding it costs 0.24ms and reading the whole window list
    /// costs 0.756ms. Caching it is what makes watching the Dock cheap enough
    /// to simply do every tick instead of guarding it behind heuristics.
    private var dockList: AXUIElement?

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
        if let p = placement.position(forScreen: id),
           Self.isOnAScreen(NSPoint(x: p.x, y: p.y)) {
            anchor = NSPoint(x: p.x, y: p.y)
        } else {
            anchor = Self.defaultAnchor(for: screen)
        }
        resizeToFit()
    }

    /// Global CG coordinates are measured from the top-left of the PRIMARY
    /// display, so this is the only height that converts them correctly -- using
    /// the active screen's height is wrong the moment a second display exists.
    private static func primaryHeight() -> CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens[0]).frame.height
    }

    private static func axFrame(_ e: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success,
              let pval = pv, let sval = sv,
              CFGetTypeID(pval) == AXValueGetTypeID(), CFGetTypeID(sval) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pval as! AXValue, .cgPoint, &p)
        AXValueGetValue(sval as! AXValue, .cgSize, &sz)
        return CGRect(origin: p, size: sz)
    }

    /// Find and cache the Dock's icon list. Re-acquired transparently whenever a
    /// Dock restart (`killall Dock`, a settings change) invalidates our handle.
    private func acquireDockList() -> AXUIElement? {
        if let l = dockList, Self.axFrame(l) != nil { return l }
        dockList = nil
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(
                  withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        // Never let a wedged Dock stall our main thread.
        AXUIElementSetMessagingTimeout(app, 0.25)
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &kids) == .success,
              let list = (kids as? [AXUIElement])?.first else { return nil }
        AXUIElementSetMessagingTimeout(list, 0.25)
        dockList = list
        return list
    }

    /// The top edge of the Dock in bottom-left coordinates, or nil when it is
    /// hidden or lives on another display.
    ///
    /// The Dock has no window of its own to measure: when auto-hidden it reports
    /// only a full-screen layer, so reading the window list yielded the top of the
    /// SCREEN and flung the pill upward. Accessibility reports the icon list's
    /// real frame -- flush off the bottom edge when hidden, lifted when shown.
    private func revealedDockTop(on screen: NSScreen) -> CGFloat? {
        guard let list = acquireDockList(), let f = Self.axFrame(list) else { return nil }
        let nsTop = Self.primaryHeight() - f.minY
        guard nsTop > 2 else { return nil }                    // flush off-screen = hidden
        guard f.midX >= screen.frame.minX, f.midX <= screen.frame.maxX else { return nil }
        return nsTop
    }

    /// Follow the Dock: rest low when it is hidden, glide up when it appears.
    private func startDockWatch() {
        dockWatchTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.followDockVisibility()
        }
        RunLoop.main.add(t, forMode: .common)
        dockWatchTimer = t
    }

    /// Behind `vf_dock_debug`, so a placement complaint can be diagnosed from a
    /// log instead of guessed at.
    private func dockLog(_ s: @autoclosure () -> String) {
        guard UserDefaults.standard.bool(forKey: "vf_dock_debug") else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [dock] \(s())\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/whispertype-client.log") {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        }
    }

    private func followDockVisibility() {
        guard let screen = Self.activeScreen() ?? NSScreen.main else { return }
        let probe = revealedDockTop(on: screen)
        dockLog("trusted=\(AXIsProcessTrusted()) list=\(dockList != nil) top=\(probe.map { String(Int($0)) } ?? "nil") mouseY=\(Int(NSEvent.mouseLocation.y))")
        let target = probe.map { $0 + 10 }
            ?? (screen.visibleFrame.minY + 14)
        guard abs(target - lastDockTop) > 1 else { return }
        lastDockTop = target
        anchor = NSPoint(x: anchor?.x ?? screen.visibleFrame.midX, y: target)
        // Glide rather than jump: the Dock animates, so we animate with it.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            resizeToFit()
        }
    }

    private func initialAnchor() -> NSPoint {
        // A saved position is only trustworthy if it still lands on a screen that
        // exists. This one was {3838, 56} from a second display that is no longer
        // connected, so the dock was clamped hard against the right edge of the
        // remaining monitor. Validate rather than migrate: unplugging a monitor
        // should not strand the dock, ever.
        if let saved = Self.loadSavedOrigin(), Self.isOnAScreen(saved) { return saved }
        return Self.defaultAnchor(for: Self.activeScreen())
    }

    /// Is this point actually on a connected display?
    private static func isOnAScreen(_ p: NSPoint) -> Bool {
        NSScreen.screens.contains { NSPointInRect(p, $0.frame) }
    }

    /// Centred, and high enough that the macOS Dock cannot sit on top of it.
    static func defaultAnchor(for screen: NSScreen?) -> NSPoint {
        guard let screen = screen ?? NSScreen.main else { return .zero }
        let v = screen.visibleFrame
        // Start low; the Dock watcher lifts us the moment the Dock appears.
        // Start low; the Dock watcher lifts us on its first tick.
        return NSPoint(x: v.midX, y: v.minY + 14)
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
