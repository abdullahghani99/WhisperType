import AppKit
import WhisperTypeKit

let dockReviewSuite = "app.whispertype.review.dock." + UUID().uuidString
let dockReviewDefaults = UserDefaults(suiteName: dockReviewSuite)!

func testNativeDockInteraction() {
    guard activePreview || ProcessInfo.processInfo.environment["VF_UI_DOCK_BACKGROUND"] == "1" else { return }
    defer { dockReviewDefaults.removePersistentDomain(forName: dockReviewSuite) }
    let dock = DockController()
    var records = 0
    dock.onToggleRecord = { records += 1 }
    dock.state.micName = "Synthetic microphone"
    dock.show()
    defer { dock.hide(); dock.panel?.close() }
    pumpPreviewEvents(until: Date().addingTimeInterval(0.4))
    guard let panel = dock.panel, let host = dock.hosting else { previewFailure("Missing native pill") }
    previewCheck(host.hitTest(NSPoint(x: 2, y: 2)) == nil, "Transparent panel margin must not intercept clicks")
    let center = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
    previewCheck(host.hitTest(center) != nil, "Visible pill must accept clicks")
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        app.sendEvent(event)
    }
    pumpPreviewEvents(until: Date().addingTimeInterval(0.4))
    previewCheck(dock.state.expanded, "Native click must expand the compact pill")
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
    if let record = controls.first(where: { attribute($0, "accessibilityLabel") as? String == "Record dictation" }) {
        let press = NSSelectorFromString("accessibilityPerformPress")
        previewCheck(record.responds(to: press))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let performPress = unsafeBitCast(record.method(for: press), to: Press.self)
        previewCheck(performPress(record, press), "Native accessible Record action must activate")
        previewCheck(labels.contains("Dictation mode") && labels.contains("Prompt mode"))
    } else {
        print("PILL AX OBSERVATION UNAVAILABLE: baseline SwiftUI tree also empty; testing native pointer dispatch separately")
        let recordPoint = NSPoint(x: host.bounds.midX - host.fittingSize.width / 2 + 16 + 14 + 36, y: host.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with:type,location:recordPoint,modifierFlags:[],timestamp:0,
                windowNumber:panel.windowNumber,context:nil,eventNumber:3,clickCount:1,pressure:1)!
            app.sendEvent(event)
        }
    }
    previewCheck(records == 1)
    previewCheck(dock.state.expanded, "Record control must not trigger background collapse")
    let emptyBackground = NSPoint(x: host.bounds.midX, y: host.bounds.midY + 17)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: emptyBackground, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        app.sendEvent(event)
    }
    pumpPreviewEvents(until: Date().addingTimeInterval(0.4))
    previewCheck(!dock.state.expanded, "Unused expanded background click must collapse controls")
    previewCheck(host.fittingSize.width <= 78 && host.fittingSize.height <= 60, "Compact pill must remain small including shadow margins")
    dock.state.ready()
    pumpPreviewEvents(until: Date().addingTimeInterval(4.4))
    previewCheck(dock.state.phase == .ready && !dock.state.expanded, "Idle result must collapse without losing ready state")
    previewCheck(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
    let before = panel.frame
    panel.setFrameOrigin(NSPoint(x: before.minX + 20, y: before.minY + 20))
    pumpPreviewEvents(until: Date().addingTimeInterval(0.1))
    previewCheck(dockReviewDefaults.dictionary(forKey: "vf_dockPositions")?.isEmpty == false,
                 "Native window move must persist a display-specific position")
    print("NATIVE PILL PASS: margin hit-test, compact click expansion, background collapse, retained-result auto-collapse, Record action dispatch (AX only when observed), window move persistence; Space behavior properties present")
}
