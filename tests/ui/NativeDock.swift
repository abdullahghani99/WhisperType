import AppKit
import WhisperTypeKit

let dockReviewSuite = "app.whispertype.review.dock." + UUID().uuidString
let dockReviewDefaults = UserDefaults(suiteName: dockReviewSuite)!

func testNativeDockInteraction() {
    guard activePreview || ProcessInfo.processInfo.environment["VF_UI_DOCK_BACKGROUND"] == "1" else { return }
    defer { dockReviewDefaults.removePersistentDomain(forName: dockReviewSuite) }
    let dock = DockController(defaults: dockReviewDefaults)
    var records = 0
    dock.onToggleRecord = { records += 1 }
    dock.state.micName = "Synthetic microphone"; dock.show()
    defer { dock.hide(); dock.panel?.close() }
    pumpPreviewEvents(until: Date().addingTimeInterval(0.25))
    guard let panel = dock.panel, let host = dock.hosting, let screen = NSScreen.main else { previewFailure("Missing native pill") }
    var timestamp = ProcessInfo.processInfo.systemUptime
    func send(_ type: NSEvent.EventType, _ point: CGPoint) {
        timestamp += 0.02
        let event = NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point), modifierFlags: [], timestamp: timestamp,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        app.sendEvent(event)
    }
    func center() -> CGPoint { CGPoint(x: panel.frame.midX, y: panel.frame.midY) }
    func click(_ point: CGPoint) { send(.leftMouseDown, point); send(.leftMouseUp, point); pumpPreviewEvents(until: Date().addingTimeInterval(0.3)) }
    func surfaces(_ view: NSView) -> [PillDragView] { (view as? PillDragView).map { [$0] } ?? view.subviews.flatMap(surfaces) }
    func drag(from start: CGPoint, to target: CGPoint) {
        send(.leftMouseDown, start)
        send(.leftMouseDragged, CGPoint(x: start.x + 12, y: start.y + 8))
        send(.leftMouseDragged, target)
        previewCheck(dock.previewPanel?.ignoresMouseEvents == true && (dock.previewPanel?.frame.width ?? 0) >= 44, "Drag must prepare a non-intercepting placement preview")
        send(.leftMouseUp, target)
        pumpPreviewEvents(until: Date().addingTimeInterval(1.35))
    }
    previewCheck(host.hitTest(NSPoint(x: 2, y: 2)) == nil, "Transparent margin must pass through")
    previewCheck(host.hitTest(NSPoint(x: host.bounds.midX, y: host.bounds.midY)) != nil)
    let frame = screen.visibleFrame
    let positions: [(PillEdge, CGPoint)] = [(.left, CGPoint(x: frame.minX + 6, y: frame.midY)), (.right, CGPoint(x: frame.maxX - 6, y: frame.midY)),
                                           (.top, CGPoint(x: frame.midX, y: frame.maxY - 6)), (.bottom, CGPoint(x: frame.midX, y: frame.minY + 6))]
    for (edge, target) in positions {
        drag(from: center(), to: target)
        previewCheck(records == 0 && !dock.state.expanded, "Dragging compact pill must not expand or record")
        previewCheck(dock.state.placementEdge == edge, "Native drag must select \(edge), got \(dock.state.placementEdge)")
        let fit = host.fittingSize; let size = CGSize(width: fit.width - 32, height: fit.height - 32)
        let body = CGRect(x: center().x-size.width/2, y: center().y-size.height/2, width: size.width, height: size.height)
        previewCheck(frame.contains(body), "Visible capsule must remain on screen at \(edge)")
    }
    let compact = center(); send(.leftMouseDown, compact); send(.leftMouseDragged, CGPoint(x: compact.x+1,y:compact.y+1)); send(.leftMouseUp,compact)
    pumpPreviewEvents(until:Date().addingTimeInterval(0.35))
    previewCheck(dock.state.expanded && records == 0, "Sub-threshold movement remains an ordinary controls click")
    guard let grip = surfaces(host).first(where: { $0.accessibilityLabel() == "Move pill" }) else { previewFailure("Expanded native grip is missing") }
    let gripPoint = panel.convertPoint(toScreen: grip.convert(CGPoint(x:grip.bounds.midX,y:grip.bounds.midY),to:nil))
    drag(from: gripPoint, to: CGPoint(x:frame.minX+6,y:frame.midY))
    previewCheck(dock.state.expanded && dock.state.placementEdge == .left && records == 0, "Expanded grip must move without triggering controls")
    let left = center().x - host.fittingSize.width/2 + 16 + 14
    click(CGPoint(x:left+12+8+36,y:center().y))
    previewCheck(records == 1 && dock.state.expanded, "Actual Record pointer click must remain a single control action")
    let beforeControlDrag = center()
    send(.leftMouseDown,CGPoint(x:left+12+8+36,y:center().y));send(.leftMouseDragged,CGPoint(x:left+12+8+36,y:center().y+100));send(.leftMouseUp,CGPoint(x:left+12+8+36,y:center().y+100))
    previewCheck(center() == beforeControlDrag && records == 1, "Dragging away from a control must neither move the panel nor record")
    click(CGPoint(x:center().x,y:center().y+17))
    previewCheck(!dock.state.expanded, "Unused background click still collapses")
    let selected = PillPlacement(store: dockReviewDefaults)
    previewCheck(selected.preferredDisplay != nil && selected.choice(for:selected.preferredDisplay!)?.edge == .left)
    let savedCenter = center(); dock.hide()
    let restored = DockController(defaults:dockReviewDefaults, reduceMotion:{ true }); restored.state.micName="Synthetic microphone";restored.show()
    pumpPreviewEvents(until:Date().addingTimeInterval(0.3))
    previewCheck(restored.state.placementEdge == .left, "Relaunch must retain edge")
    previewCheck(abs((restored.panel?.frame.midX ?? 0)-savedCenter.x)<1, "Relaunch must retain visible position")
    restored.state.expanded=true;pumpPreviewEvents(until:Date().addingTimeInterval(0.08))
    if let restoredPanel=restored.panel, let restoredHost=restored.hosting {
        let width=restoredHost.fittingSize.width-32
        previewCheck(restoredPanel.frame.midX-width/2 >= frame.minX+13,"Side expansion must grow inward immediately")
    }
    restored.state.expanded=false;pumpPreviewEvents(until:Date().addingTimeInterval(0.08))
    previewCheck(abs((restored.panel?.frame.midX ?? 0)-savedCenter.x)<1,"Collapse returns to the same edge")
    restored.hide();restored.panel?.close();dock.show()
    pumpPreviewEvents(until:Date().addingTimeInterval(0.2))
    guard let compactSurface = surfaces(host).first(where: { $0.accessibilityLabel()?.hasPrefix("Open recording") == true }) else { previewFailure("Compact drag target missing") }
    let menuEvent = NSEvent.mouseEvent(with:.rightMouseDown,location:panel.convertPoint(fromScreen:center()),modifierFlags:[],timestamp:timestamp,windowNumber:panel.windowNumber,context:nil,eventNumber:3,clickCount:1,pressure:1)!
    guard let item = compactSurface.menu(for:menuEvent)?.items.last, let action=item.action else { previewFailure("Free placement menu missing") }
    previewCheck(app.sendAction(action,to:item.target,from:item),"Position menu action must dispatch")
    pumpPreviewEvents(until:Date().addingTimeInterval(1.35))
    let freeTarget=CGPoint(x:frame.minX+frame.width*0.36,y:frame.minY+frame.height*0.63)
    drag(from:center(),to:freeTarget)
    previewCheck(dock.state.placementEdge == .free && hypot(center().x-freeTarget.x,center().y-freeTarget.y)<1,"Free placement must track the actual release point")
    dock.state.expanded=true;pumpPreviewEvents(until:Date().addingTimeInterval(0.3));dock.state.expanded=false;pumpPreviewEvents(until:Date().addingTimeInterval(0.3))
    previewCheck(hypot(center().x-freeTarget.x,center().y-freeTarget.y)<1,"State changes must not reset manual placement")
    dock.state.begin(); pumpPreviewEvents(until:Date().addingTimeInterval(0.3))
    guard let liveGrip = surfaces(host).first(where: { $0.accessibilityLabel() == "Move pill" }) else { previewFailure("Active-state grip missing") }
    let livePoint = panel.convertPoint(toScreen:liveGrip.convert(CGPoint(x:liveGrip.bounds.midX,y:liveGrip.bounds.midY),to:nil))
    drag(from:livePoint,to:CGPoint(x:frame.midX,y:frame.midY))
    previewCheck(dock.state.phase == .listening && records == 1,"Moving an active UI state must not stop/start recording")
    dock.state.returnToIdle();dock.state.callOffer=true;dock.state.callTitle="Synthetic call";pumpPreviewEvents(until:Date().addingTimeInterval(0.3))
    previewCheck(dock.state.showsCallOffer && surfaces(host).contains(where:{$0.accessibilityLabel()=="Move pill"}),"Call offer remains visible and movable")
    dock.state.callOffer=false;dock.state.returnToIdle();pumpPreviewEvents(until:Date().addingTimeInterval(0.3))
    previewCheck(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
    previewCheck(host.fittingSize.width <= 78 && host.fittingSize.height <= 60)
    print("NATIVE PILL PASS: actual down/drag/up dispatch on compact pill and expanded grip; four edges, threshold click, Record pointer action, control-drag exclusion, background collapse, free placement, state changes, relaunch, visible-frame bounds; no microphone or external events")
}
