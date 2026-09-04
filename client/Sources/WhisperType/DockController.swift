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
    /// Cached: 0.089ms/read, against 0.756ms for a window-list scan.
    private var dockList: AXUIElement?
    /// The frame WE last set. didMoveNotification fires for programmatic moves
    /// too, so without this every resizeToFit looked like the user dragging the
    /// pill -- which is how a fresh ultra-wide display inherited the MacBook's
    /// centre (x=1028) as a "chosen" position and kept restoring it far left.
    private var lastSetFrame: NSRect?

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
                errorClearTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
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
        if p.frame != target {
            lastSetFrame = target
            p.setFrame(target, display: true)
        }
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
           NSPointInRect(NSPoint(x: p.x, y: p.y), screen.frame) {
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
        NSScreen.screens.first?.frame.height ?? 0     // screens[0] is the primary
    }

    private static func axFrame(_ e: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success,
              let pval = pv, let sval = sv,
              // Not `as?`: Swift rejects a conditional downcast to a CF type
              // ("always succeeds"), so this IS the type check guarding the `as!`.
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
        if let l = dockList { return l }
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

    /// Three genuinely different answers, because they need different responses:
    /// we can see the Dock and it is up; we can see it and it is not in our way;
    /// or we cannot see it at all and have to guess.
    private enum DockProbe {
        case top(CGFloat)
        case away
        case blind
    }

    /// Where the Dock's top edge is, in bottom-left coordinates.
    ///
    /// The Dock has no window of its own to measure: when auto-hidden it reports
    /// only a full-screen layer, so reading the window list yielded the top of the
    /// SCREEN and flung the pill upward. Accessibility reports the icon list's
    /// real frame -- flush off the bottom edge when hidden, lifted when shown.
    private func dockProbe(on screen: NSScreen) -> DockProbe {
        // One AX round trip per tick. A stale handle (the Dock restarted) simply
        // fails to answer, so re-acquire and try once more rather than paying for
        // a separate liveness probe every tick.
        var frame = acquireDockList().flatMap { Self.axFrame($0) }
        if frame == nil {
            dockList = nil
            frame = acquireDockList().flatMap { Self.axFrame($0) }
        }
        guard let f = frame else { return .blind }

        // AX reports top-left origin; convert the WHOLE rect, not just one edge.
        // Reading only the top meant a left- or right-hand Dock -- whose icon list
        // runs the height of the display -- was read as a very tall bottom Dock,
        // sending the pill to 1216pt, near the top of the screen. Measured.
        let ns = NSRect(x: f.minX, y: Self.primaryHeight() - f.maxY,
                        width: f.width, height: f.height)
        guard ns.width > ns.height else { return .away }        // side Dock: not our problem
        guard ns.midX >= screen.frame.minX, ns.midX <= screen.frame.maxX else { return .away }
        // Bottom quarter, not "flush to the edge": with Dock magnification the
        // icon list rides ~10pt above the bottom, and a 4pt tolerance rejected a
        // real revealed Dock outright. Still excludes a Dock on another display
        // in a vertically stacked arrangement.
        guard ns.minY < screen.frame.minY + screen.frame.height * 0.25 else { return .away }
        guard ns.maxY > screen.frame.minY + 2 else { return .away }    // flush off-screen = hidden
        return .top(ns.maxY)
    }

    /// Without Accessibility we cannot see the Dock at all, so fall back to what
    /// the Dock's own preferences imply. Only reachable before permission is
    /// granted -- but in exactly that window the pill would otherwise sit under a
    /// revealed Dock.
    private static func blindInset(for screen: NSScreen) -> CGFloat {
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        if reserved > 4 { return reserved + 12 }               // a pinned Dock reserves space
        let d = UserDefaults(suiteName: "com.apple.dock")
        guard d?.bool(forKey: "autohide") == true,
              (d?.string(forKey: "orientation") ?? "bottom") == "bottom" else { return 14 }
        return CGFloat(d?.double(forKey: "tilesize") ?? 48) + 34
    }

    /// Follow the Dock: rest low when it is hidden, glide up when it appears.
    private func startDockWatch() {
        dockWatchTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.followDockVisibility()
        }
        RunLoop.main.add(t, forMode: .common)
        dockWatchTimer = t
    }

    /// Behind `vf_dock_debug`, so a placement complaint can be diagnosed from a
    /// log instead of guessed at.
    private func dockLog(_ s: @autoclosure () -> String) {
        guard UserDefaults.standard.bool(forKey: "vf_dock_debug") else { return }
        vlog("[dock] \(s())")
    }

    private func followDockVisibility() {
        guard let screen = Self.activeScreen() ?? NSScreen.main else { return }
        // Re-centre when the display changes. This was written but never called,
        // so plugging in a monitor left the pill wherever the old one had put it.
        // Cheap: it returns immediately unless the screen id actually changed.
        followActiveScreen()
        let probe = dockProbe(on: screen)
        let target: CGFloat
        switch probe {
        case .top(let t): target = t + 10
        case .away:      target = screen.visibleFrame.minY + 14
        case .blind:     target = screen.frame.minY + Self.blindInset(for: screen)
        }
        dockLog("probe=\(probe) target=\(Int(target)) mouseY=\(Int(NSEvent.mouseLocation.y))")
        guard abs(target - lastDockTop) > 1 else { return }
        lastDockTop = target
        anchor = NSPoint(x: anchor?.x ?? screen.visibleFrame.midX, y: target)
        // No animation here on purpose: resizeToFit uses setFrame, which
        // NSAnimationContext does not touch, so wrapping it only looked like
        // easing. The motion you see is real -- we sample the Dock's OWN
        // animation often enough to follow it up and down.
        resizeToFit()
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
        // Our own setFrame, not a drag. Persisting these was the bug.
        if let mine = lastSetFrame, p.frame == mine { return }
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
