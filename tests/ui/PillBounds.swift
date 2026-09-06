import AppKit
import SwiftUI
import WhisperTypeKit

/// Capture only this process's native windows, behind the foreground app.
/// Baseline mode records the known failure; normal mode enforces the bounds.
func testPillBounds() {
    let baseline = ProcessInfo.processInfo.environment["VF_BOUNDS_BASELINE"] == "1"
    guard let screen = NSScreen.main else { previewFailure("No display for bounds check") }
    let labels = baseline ? ["Requested: Alex’s AirPods Pro"] : [
        "Requested: Alex’s AirPods Pro",
        "Requested: External conference microphone with an exceptionally long device name and connection description",
        "Switching: Microphone externe avec un nom très long — Conference USB Audio Interface",
        "No microphone available"
    ]
    var results: [[String:Any]] = []
    for (index, label) in labels.enumerated() {
        for edge in (baseline || index > 0 ? [PillEdge.bottom] : [.top, .bottom, .left, .right]) {
            let state = DockState();state.expanded=true;state.serverOK=true;state.micName=label;state.placementEdge=edge
            let host = DockHostingView(rootView: DockView(state:state,onToggleRecord:{},onPickMic:{_ in},onToggleMode:{},onMeeting:{},onSettings:{},micDevices:{[]}))
            host.sizingOptions = [.intrinsicContentSize]
            let panel = NSPanel(contentRect:CGRect(origin:.zero,size:DockController.panelSize),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.contentView=host;panel.backgroundColor = .clear;panel.isOpaque=false;panel.hasShadow=false
            panel.isReleasedWhenClosed=false;panel.becomesKeyOnlyIfNeeded=true;panel.appearance=NSAppearance(named:.darkAqua)
            panel.setFrame(CGRect(x:screen.visibleFrame.midX-310,y:screen.visibleFrame.midY-52,width:620,height:104),display:true)
            panel.orderBack(nil);host.layoutSubtreeIfNeeded();pumpPreviewEvents(until:Date().addingTimeInterval(0.35))
            let fit=host.fittingSize
            let capsule=CGSize(width:fit.width-32,height:fit.height-32)
            let center=PillGeometry.center(edge:edge,size:capsule,in:screen.visibleFrame)
            panel.setFrameOrigin(CGPoint(x:center.x-panel.frame.width/2,y:center.y-panel.frame.height/2))
            panel.orderBack(nil); host.needsDisplay = true; panel.displayIfNeeded()
            pumpPreviewEvents(until:Date().addingTimeInterval(0.6))
            let tag="\(baseline ? "Before" : "After")-\(index)-\(edge.rawValue)"
            guard let image=captureOwnWindow(panel) else { panel.close();previewFailure("Native bounds screenshot unavailable") }
            let rep=NSBitmapImageRep(cgImage:image)
            guard let png=rep.representation(using:.png,properties:[:]) else { previewFailure("PNG encoding failed") }
            do { try png.write(to:out.appendingPathComponent("Pill-\(tag).png")) }
            catch { panel.close(); previewFailure("PNG could not be saved: \(error)") }
            let left=rep.colorAt(x:1,y:rep.pixelsHigh/2)?.alphaComponent ?? 1
            let middle=rep.colorAt(x:rep.pixelsWide/2,y:rep.pixelsHigh/2)?.alphaComponent ?? 0
            let right=rep.colorAt(x:rep.pixelsWide-2,y:rep.pixelsHigh/2)?.alphaComponent ?? 1
            print("PILL BOUNDS",tag,"fitting",fit,"host",host.bounds.size,"pixels",rep.pixelsWide,rep.pixelsHigh,"edge alpha",left,right)
            results.append(["case":tag,"fittingWidth":fit.width,"hostWidth":host.bounds.width,"pixelsWide":rep.pixelsWide,"pixelsHigh":rep.pixelsHigh,"leftEdgeAlpha":left,"rightEdgeAlpha":right])
            previewCheck(middle > 0.9,"Capture must contain the opaque expanded pill, not an empty window")
            if !baseline {
                previewCheck(fit.width <= host.bounds.width && fit.height <= host.bounds.height,"Expanded content must fit its actual host with shadow padding")
                previewCheck(left < 0.15 && right < 0.15,"Both ends must have clear raster margins, not cut through the capsule")
                let visible=CGRect(x:center.x-capsule.width/2,y:center.y-capsule.height/2,width:capsule.width,height:capsule.height)
                previewCheck(screen.visibleFrame.contains(visible),"Expanded capsule must fit selected screen at \(edge)")
                let constrained=CGRect(x:-800,y:0,width:800,height:560)
                let constrainedCenter=PillGeometry.center(edge:edge,size:capsule,in:constrained)
                previewCheck(constrained.contains(CGRect(x:constrainedCenter.x-capsule.width/2,y:constrainedCenter.y-capsule.height/2,width:capsule.width,height:capsule.height)),"Expanded capsule must fit 800pt visible width")
            }
            panel.orderOut(nil);panel.close()
        }
    }
    do {
        let data=try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]);try data.write(to:out.appendingPathComponent("pill-bounds.json"))
    } catch { previewFailure("Bounds evidence could not be saved: \(error)") }
    print("COMPLETE: native pill bounds and full-window raster capture",baseline ? "baseline" : "verified")
}
