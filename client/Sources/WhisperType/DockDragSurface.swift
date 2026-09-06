import AppKit
import SwiftUI
import WhisperTypeKit

public enum PillDragEvent {
    case began(CGPoint), moved(CGPoint), ended(CGPoint, CGPoint)
}

/// A real responder owns down/drag/up, including in a nonactivating panel.
/// SwiftUI's compact Button previously consumed the only usable drag area.
final class PillDragView: NSView {
    var click: () -> Void = {}
    var drag: (PillDragEvent) -> Void = { _ in }
    var select: (PillEdge) -> Void = { _ in }
    var edge: PillEdge = .bottom
    var showsCursor = true
    private var down: CGPoint?
    private var previous: (CGPoint, TimeInterval)?
    private var velocity = CGPoint.zero
    private var dragging = false
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { if showsCursor { addCursorRect(bounds, cursor: .openHand) } }
    private func point(_ event: NSEvent) -> CGPoint { window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow }
    override func mouseDown(with event: NSEvent) {
        down = point(event); previous = (point(event), event.timestamp); velocity = .zero; dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        let current = point(event)
        if !dragging && hypot(current.x - down.x, current.y - down.y) >= 6 {
            dragging = true; NSCursor.closedHand.set(); drag(.began(down))
        }
        if let previous, event.timestamp > previous.1 {
            let dt = event.timestamp - previous.1
            velocity = CGPoint(x: max(-1800, min(1800, (current.x - previous.0.x) / dt)),
                               y: max(-1800, min(1800, (current.y - previous.0.y) / dt)))
        }
        previous = (current, event.timestamp)
        if dragging { drag(.moved(current)) }
    }
    override func mouseUp(with event: NSEvent) {
        guard down != nil else { return }
        if dragging {
            let v = previous.map { event.timestamp - $0.1 < 0.12 ? velocity : .zero } ?? .zero
            drag(.ended(point(event), v))
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) { click() }
        down = nil; previous = nil; dragging = false; NSCursor.arrow.set()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Pill position")
        for (title, value) in [("Top", PillEdge.top), ("Bottom", .bottom), ("Left", .left), ("Right", .right), ("Free placement", .free)] {
            if value == .free { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: #selector(choosePosition(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value.rawValue; item.state = value == edge ? .on : .off; menu.addItem(item)
        }
        return menu
    }
    @objc private func choosePosition(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let value = PillEdge(rawValue: raw) { select(value) }
    }
    override func accessibilityPerformPress() -> Bool { click(); return true }
}

struct DockDragSurface: NSViewRepresentable {
    let label: String?
    let edge: PillEdge
    let onClick: () -> Void
    let onDrag: (PillDragEvent) -> Void
    let onSelect: (PillEdge) -> Void
    func makeNSView(context: Context) -> PillDragView { PillDragView() }
    func updateNSView(_ view: PillDragView, context: Context) {
        view.click = onClick; view.drag = onDrag; view.select = onSelect; view.edge = edge
        view.showsCursor = label != nil
        view.setAccessibilityElement(label != nil)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(label)
        view.toolTip = "Drag to move · right-click for position"
    }
}

final class PillDockPreview: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 18, yRadius: 18)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill(); path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke(); path.lineWidth = 2; path.stroke()
    }
}
