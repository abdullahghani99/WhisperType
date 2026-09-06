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
        return box.insetBy(dx: 16, dy: 16).contains(point) ? super.hitTest(point) : nil
    }
}
import Combine
import WhisperTypeKit

/// Hosts `DockView` in a floating, non-activating `NSPanel` that sits ABOVE
/// every other window — including a Screen Sharing / VNC session window.
/// This is what makes the dock usable while the "active" surface on screen
/// is actually a remote desktop: the panel is never part of that remote
/// window, it floats over the whole local display independent of Spaces.
private final class RecordingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DockController {
    let state = DockState()
    private var panel: NSPanel?
    private var hosting: NSHostingView<DockView>?
    private var cancellable: AnyCancellable?
    /// Visible capsule center; edge placement moves expansion inward on screen.
    private var anchor: NSPoint?
    /// Where the dock sits on EACH display. One shared position meant it stayed
    /// on whichever screen was main at launch — which is why it kept turning up
    /// off to one side on a multi-monitor desk.
    private let placement: PillPlacement
    private let defaults: UserDefaults
    private let reduceMotion: () -> Bool
    private var choice = PillPlacement.Choice()
    private var isDragging = false
    private var dragStart = CGPoint.zero
    private var dragOrigin = CGPoint.zero
    private var dragScreen: NSScreen?
    private var previewEdge: PillEdge?
    private var previewPanel: NSPanel?
    private var snapTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var cachedProbe: DockProbe = .away
    private var probeScreenID: String?

    init(defaults: UserDefaults = .standard, reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.reduceMotion = reduceMotion
        self.defaults = defaults; self.placement = PillPlacement(store: defaults)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.followActiveScreen(); self?.resizeToFit()
        }
    }
    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        snapTimer?.invalidate(); dockWatchTimer?.invalidate(); collapseTimer?.invalidate()
        elapsedTimer?.invalidate(); successTimer?.invalidate()
    }
    private var lastScreenID: String?

    var onToggleRecord: () -> Void = {}
    var onPickMic: (String) -> Void = { _ in }
    var onToggleMode: () -> Void = {}
    var onMeeting: () -> Void = {}
    var onAcceptCall: () -> Void = {}
    var onSettings: () -> Void = {}
    var onRecovery: () -> Void = {}
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

    func hide() { panel?.orderOut(nil); previewPanel?.orderOut(nil); snapTimer?.invalidate(); snapTimer = nil; dockWatchTimer?.invalidate(); dockWatchTimer = nil }

    /// Explicit keyboard entry; ordinary pointer use remains non-activating.
    func focusControls() {
        show(); state.expanded = true
        panel?.makeKeyAndOrderFront(nil)
        panel?.selectNextKeyView(nil)
    }

    // MARK: - Panel construction

    private func makePanel() -> NSPanel {
        let view = DockView(
            state: state,
            onToggleRecord: { [weak self] in self?.onToggleRecord() },
            onPickMic: { [weak self] uid in self?.onPickMic(uid) },
            onToggleMode: { [weak self] in self?.onToggleMode() },
            onMeeting: { [weak self] in self?.onMeeting() },
            onSettings: { [weak self] in self?.onSettings() },
            micDevices: { [weak self] in self?.micDevices() ?? [] },
            onRecovery: { [weak self] in self?.onRecovery() },
            onHoverChanged: { [weak self] over in self?.hoverChanged(over) },
            onAcceptCall: { [weak self] in self?.onAcceptCall() },
            onDrag: { [weak self] event in self?.handleDrag(event) },
            onSelectPosition: { [weak self] edge in self?.choosePosition(edge) }
        )
        let host = DockHostingView(rootView: view)
        if #available(macOS 13.0, *) { host.sizingOptions = [.intrinsicContentSize] }
        hosting = host

        let p = RecordingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.contentView = host
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.isMovableByWindowBackground = false
        p.isReleasedWhenClosed = false

        // React to state changes: re-fit the panel (only when the SIZE actually
        // changes — not on every audio-level tick) and run the elapsed timer.
        cancellable = state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.stateChanged() }

        return p
    }

    // MARK: - Sizing / positioning

    private var collapseTimer: Timer?
    private var pointerOverDock = false
    private var lastExpanded = false
    private func hoverChanged(_ over: Bool) {
        pointerOverDock = over
        collapseTimer?.invalidate(); collapseTimer = nil
        if !over { scheduleCollapse(after: 1.2) }
    }
    private func scheduleCollapse(after delay: TimeInterval = 4) {
        collapseTimer?.invalidate(); collapseTimer = nil
        guard !isDragging, state.expanded, state.canCollapsePresentation else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, !self.pointerOverDock, self.panel?.isKeyWindow != true else { return }
            self.state.collapsePresentation()
        }
    }
    private var elapsedTimer: Timer?
    private var successTimer: Timer?
    private var lastPhase: DockState.Phase = .idle

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
    /// Cached: 0.089ms/read, against 0.756ms for a window-list scan.
    private var dockList: AXUIElement?
    private func shapeKey() -> String {
        "\(state.phase)|\(state.expanded)|\(state.callOffer)|\(state.micName)|\(state.errorText)|\(state.callTitle)|\(state.meetingRecording)|\(state.meetingMicTrouble)"
    }

    private func stateChanged() {
        // Elapsed timer: tick once per second while listening.
        if state.phase == .listening || state.meetingRecording {
            if elapsedTimer == nil {
                elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    if self?.state.phase == .listening { self?.state.elapsed += 1 }
                    if self?.state.meetingRecording == true { self?.state.meetingElapsed += 1 }
                }
            }
        } else {
            elapsedTimer?.invalidate(); elapsedTimer = nil
        }
        if state.phase != lastPhase || state.expanded != lastExpanded {
            scheduleCollapse()
            lastExpanded = state.expanded
        }
        if state.phase != lastPhase {
            lastPhase = state.phase
            successTimer?.invalidate(); successTimer = nil
            if state.phase == .done {
                successTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                    guard let self = self, self.state.phase == .done else { return }
                    self.state.returnToIdle()
                }
            }
        }
        // Errors remain actionable until dismissed or superseded by capture.
        let key = shapeKey()
        if key != lastShape { lastShape = key; resizeToFit() }
    }

    /// Reserve a stable animation canvas, with enough room for intrinsic content
    /// and its shadow padding. The visible capsule stays anchored at its center.
    private var capsuleSize: CGSize {
        hosting?.layoutSubtreeIfNeeded()
        let fit = hosting?.fittingSize ?? CGSize(width: 76, height: 56)
        return CGSize(width: max(44, fit.width - 32), height: max(24, fit.height - 32))
    }
    private func resizeToFit() {
        guard panel != nil, !isDragging, snapTimer == nil, let screen = selectedScreen() else { return }
        anchor = targetCenter(on: screen)
        if let anchor { moveCenter(anchor) }
    }
    private func moveCenter(_ center: CGPoint) {
        let fit = hosting?.fittingSize ?? Self.panelSize
        let size = NSSize(width: max(Self.panelSize.width, fit.width),
                          height: max(Self.panelSize.height, fit.height))
        let target = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                            width: size.width, height: size.height)
        if panel?.frame != target { panel?.setFrame(target, display: true) }
    }
    static let panelSize = NSSize(width: 620, height: 104)
    static let verticalPadding: CGFloat = 34

    private static func screenID(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let number else { return "display-unknown" }
        if let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display-\(number.uint32Value)"
    }
    private static func legacyScreenID(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return "\(number?.intValue ?? 0)-\(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }
    private static func activeScreen() -> NSScreen? { screen(at: NSEvent.mouseLocation) }
    private static func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.screens.min {
            hypot($0.frame.midX - point.x, $0.frame.midY - point.y) < hypot($1.frame.midX - point.x, $1.frame.midY - point.y)
        }
    }
    private func selectedScreen() -> NSScreen? {
        NSScreen.screens.first { Self.screenID($0) == lastScreenID } ?? NSScreen.main ?? NSScreen.screens.first
    }
    private static func safeFrame(_ screen: NSScreen) -> CGRect {
        var frame = screen.visibleFrame
        frame.size.height = max(1, min(frame.maxY, screen.frame.maxY - screen.safeAreaInsets.top) - frame.minY)
        return frame
    }
    private func availableFrame(on screen: NSScreen) -> CGRect {
        var frame = Self.safeFrame(screen)
        guard probeScreenID == Self.screenID(screen) else { return frame }
        switch cachedProbe {
        case .top(let top) where choice.edge == .bottom || choice.edge == .free:
            let bottom = max(frame.minY, top + 10); frame.size.height = max(1, frame.maxY - bottom); frame.origin.y = bottom
        case .left(let right) where choice.edge == .left || choice.edge == .free:
            let left = max(frame.minX, right + 10); frame.size.width = max(1, frame.maxX - left); frame.origin.x = left
        case .right(let left) where choice.edge == .right || choice.edge == .free:
            frame.size.width = max(1, min(frame.maxX, left - 10) - frame.minX)
        case .blind where choice.edge == .bottom:
            let bottom = max(frame.minY, screen.frame.minY + Self.blindInset(for: screen)); frame.size.height = max(1, frame.maxY - bottom); frame.origin.y = bottom
        default: break
        }
        return frame
    }
    private func targetCenter(on screen: NSScreen) -> CGPoint {
        let base = Self.safeFrame(screen)
        let point = PillGeometry.center(edge: choice.edge, size: capsuleSize, in: choice.edge == .free ? base : availableFrame(on: screen), x: choice.x, y: choice.y)
        return PillGeometry.clamp(point, size: capsuleSize, in: availableFrame(on: screen))
    }
    /// The chosen display stays put when the pointer moves to another display.
    /// A disconnected display falls back safely; its saved choice remains available.
    func followActiveScreen() {
        guard !isDragging else { return }
        let preferred = placement.preferredDisplay.flatMap { id in NSScreen.screens.first { Self.screenID($0) == id } }
        guard let screen = preferred ?? NSScreen.screens.first(where: { Self.screenID($0) == lastScreenID }) ?? Self.activeScreen() else { return }
        let id = Self.screenID(screen)
        guard lastScreenID != id else { return }
        lastScreenID = id
        if let saved = placement.choice(for: id) { choice = saved }
        else if let old = DockPlacement(store: defaults).position(forScreen: Self.legacyScreenID(screen)), screen.frame.contains(CGPoint(x: old.x, y: old.y)) {
            let point = PillGeometry.normalized(CGPoint(x: old.x, y: old.y + 18), in: Self.safeFrame(screen))
            choice = .init(edge: .free, x: point.x, y: point.y); placement.remember(choice, display: id)
        } else if let raw = defaults.string(forKey: Self.originDefaultsKey), screen.frame.contains(NSPointFromString(raw)), NSPointFromString(raw) != .zero {
            let old = NSPointFromString(raw); let point = PillGeometry.normalized(CGPoint(x: old.x, y: old.y + 18), in: Self.safeFrame(screen))
            choice = .init(edge: .free, x: point.x, y: point.y); placement.remember(choice, display: id)
        } else { choice = .init() }
        state.placementEdge = choice.edge; cachedProbe = .away; probeScreenID = nil
        resizeToFit()
    }
    private func initialAnchor() -> NSPoint {
        followActiveScreen()
        return selectedScreen().map { targetCenter(on: $0) } ?? .zero
    }
    static func defaultAnchor(for screen: NSScreen?) -> NSPoint {
        guard let screen = screen ?? NSScreen.main else { return .zero }
        return PillGeometry.center(edge: .bottom, size: CGSize(width: 44, height: 24), in: Self.safeFrame(screen))
    }

    private func handleDrag(_ event: PillDragEvent) {
        guard let panel else { return }
        switch event {
        case .began(let point):
            snapTimer?.invalidate(); snapTimer = nil; collapseTimer?.invalidate()
            vlog("pill drag began")
            isDragging = true; dragStart = point; dragOrigin = CGPoint(x: panel.frame.midX, y: panel.frame.midY); previewEdge = nil
        case .moved(let point):
            guard isDragging, let screen = Self.screen(at: point) else { return }
            dragScreen = screen
            let center = CGPoint(x: dragOrigin.x + point.x - dragStart.x, y: dragOrigin.y + point.y - dragStart.y)
            anchor = center; moveCenter(center)
            previewEdge = choice.edge == .free ? .free : PillGeometry.nearestEdge(to: point, in: Self.safeFrame(screen), previous: previewEdge)
            let target = previewEdge == .free ? PillGeometry.clamp(center, size: capsuleSize, in: Self.safeFrame(screen)) : PillGeometry.center(edge: previewEdge ?? .bottom, size: capsuleSize, in: Self.safeFrame(screen))
            showPreview(at: target)
        case .ended(let point, let velocity):
            guard isDragging else { return }
            handleDrag(.moved(point)); isDragging = false; previewPanel?.orderOut(nil)
            guard let screen = dragScreen ?? selectedScreen() else { return }
            lastScreenID = Self.screenID(screen)
            let normalized = PillGeometry.normalized(anchor ?? point, in: Self.safeFrame(screen))
            choice = .init(edge: previewEdge ?? .bottom, x: normalized.x, y: normalized.y)
            placement.remember(choice, display: Self.screenID(screen)); state.placementEdge = choice.edge
            vlog("pill placed: edge=\(choice.edge.rawValue)")
            settle(to: targetCenter(on: screen), velocity: velocity); scheduleCollapse()
        }
    }
    private func choosePosition(_ edge: PillEdge) {
        guard let screen = selectedScreen(), let panel else { return }
        let normalized = PillGeometry.normalized(CGPoint(x: panel.frame.midX, y: panel.frame.midY), in: Self.safeFrame(screen))
        choice = .init(edge: edge, x: normalized.x, y: normalized.y)
        placement.remember(choice, display: Self.screenID(screen)); state.placementEdge = edge
        settle(to: targetCenter(on: screen), velocity: .zero)
    }
    private func showPreview(at center: CGPoint) {
        if previewPanel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false; p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false; p.contentView = PillDockPreview(); previewPanel = p
        }
        let size = capsuleSize
        previewPanel?.setFrame(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), display: true)
        previewPanel?.orderFrontRegardless()
    }
    private func settle(to target: CGPoint, velocity: CGPoint) {
        snapTimer?.invalidate(); snapTimer = nil; anchor = target
        guard !reduceMotion() else { moveCenter(target); return }
        var speed = velocity
        var last = ProcessInfo.processInfo.systemUptime
        let started = last
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, let panel = self.panel else { timer.invalidate(); return }
            let now = ProcessInfo.processInfo.systemUptime; let dt = min(1.0 / 30, now - last); last = now
            var center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            speed.x += (324 * (target.x - center.x) - 36 * speed.x) * dt
            speed.y += (324 * (target.y - center.y) - 36 * speed.y) * dt
            center.x += speed.x * dt; center.y += speed.y * dt
            if (hypot(target.x - center.x, target.y - center.y) < 0.4 && hypot(speed.x, speed.y) < 3) || now - started > 1.2 {
                timer.invalidate(); self.snapTimer = nil; self.moveCenter(target); self.resizeToFit()
            } else { self.moveCenter(center) }
        }
        timer.tolerance = 0.003; RunLoop.main.add(timer, forMode: .common); snapTimer = timer
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
    private enum DockProbe: Equatable {
        case top(CGFloat)
        case left(CGFloat)
        case right(CGFloat)
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
        if ns.width <= ns.height {
            guard ns.midY >= screen.frame.minY, ns.midY <= screen.frame.maxY else { return .away }
            if ns.minX <= screen.frame.minX + 4 && ns.maxX > screen.frame.minX + 2 { return .left(ns.maxX) }
            if ns.maxX >= screen.frame.maxX - 4 && ns.minX < screen.frame.maxX - 2 { return .right(ns.minX) }
            return .away
        }
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
        let screen = selectedScreen()
        let nearDock = screen.map { NSEvent.mouseLocation.y < $0.visibleFrame.minY + 180 } ?? false
        let delay = nearDock ? 0.1 : 0.75
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, self.panel?.isVisible == true else { return }
            self.followDockVisibility()
            self.startDockWatch()
        }
        timer.tolerance = nearDock ? 0.02 : 0.15
        RunLoop.main.add(timer, forMode: .common)
        dockWatchTimer = timer
    }

    private func followDockVisibility() {
        guard !isDragging, snapTimer == nil else { return }
        followActiveScreen()
        guard let screen = selectedScreen() else { return }
        cachedProbe = dockProbe(on: screen); probeScreenID = Self.screenID(screen)
        resizeToFit()
    }
}
