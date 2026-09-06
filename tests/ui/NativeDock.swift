import AppKit
import WhisperTypeKit

let dockReviewSuite = "app.whispertype.review.dock." + UUID().uuidString
let dockReviewDefaults = UserDefaults(suiteName: dockReviewSuite)!

func testNativeDockInteraction() {
    guard activePreview else { return }
    defer { dockReviewDefaults.removePersistentDomain(forName: dockReviewSuite) }
    let dock = DockController()
    var records = 0
    dock.onToggleRecord = { records += 1 }
    dock.state.micName = "Synthetic microphone"
    dock.show()
    defer { dock.hide(); dock.panel?.close() }
    pumpPreviewEvents(until: Date().addingTimeInterval(0.4))
    guard let panel = dock.panel, let host = dock.hosting else { preconditionFailure("Missing native pill") }
    precondition(host.hitTest(NSPoint(x: 2, y: 2)) == nil, "Transparent panel margin must not intercept clicks")
    let center = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
    precondition(host.hitTest(center) != nil, "Visible pill must accept clicks")
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        app.sendEvent(event)
    }
    pumpPreviewEvents(until: Date().addingTimeInterval(0.4))
    precondition(dock.state.expanded, "Native click must expand the compact pill")
    var controls: [NSObject] = []
    func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }
    func walk(_ object: Any, depth: Int = 0) {
        guard depth < 15, let node = object as? NSObject else { return }
        controls.append(node)
        for child in attribute(node, "accessibilityChildren") as? [Any] ?? [] { walk(child, depth: depth + 1) }
    }
    walk(host)
    let labels = controls.compactMap { attribute($0, "accessibilityLabel") as? String }
    print("PILL AX LABELS", labels)
    guard let record = controls.first(where: { attribute($0, "accessibilityLabel") as? String == "Record dictation" }) else {
        preconditionFailure("Accessible Record action missing: \(labels)")
    }
    let press = NSSelectorFromString("accessibilityPerformPress")
    precondition(record.responds(to: press))
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    let performPress = unsafeBitCast(record.method(for: press), to: Press.self)
    precondition(performPress(record, press), "Native accessible Record action must activate")
    precondition(records == 1)
    precondition(labels.contains("Dictation mode") && labels.contains("Prompt mode"))
    precondition(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
    let before = panel.frame
    panel.setFrameOrigin(NSPoint(x: before.minX + 20, y: before.minY + 20))
    pumpPreviewEvents(until: Date().addingTimeInterval(0.1))
    precondition(dockReviewDefaults.dictionary(forKey: "vf_dockPositions")?.isEmpty == false,
                 "Native window move must persist a display-specific position")
    print("NATIVE PILL PASS: margin hit-test, compact click expansion, accessible Record/mode controls, action dispatch, window move persistence; Space behavior properties present")
}
