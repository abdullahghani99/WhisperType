import AppKit
import SwiftUI
import WhisperTypeKit

/// Exercise the real SwiftUI control tree without posting input to another app.
func testNativeCaptureControls() {
    guard activePreview else { return }
    let state = SettingsState(); let nav = MainNav()
    state.serverOK = true; state.microphonePermission = "Allowed"
    var recordings = 0, meetings = 0, imports = 0, cancels = 0
    state.onToggleRecording = { recordings += 1 }
    state.onToggleMeeting = { meetings += 1 }
    state.onImportRecording = { imports += 1 }
    state.onCancelImport = { cancels += 1 }
    let controller = NSHostingController(rootView: CaptureHome(state: state, nav: nav))
    let window = NSWindow(contentViewController: controller)
    window.setContentSize(NSSize(width: 800, height: 900))
    window.isReleasedWhenClosed = false
    app.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    func attribute(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }
    func find(_ label: String) -> NSObject {
        pumpPreviewEvents(until: Date().addingTimeInterval(0.2))
        var nodes: [NSObject] = []
        func walk(_ value: Any, depth: Int = 0) {
            guard depth < 20, let node = value as? NSObject else { return }
            nodes.append(node)
            for child in attribute(node,"accessibilityChildren") as? [Any] ?? [] { walk(child,depth:depth+1) }
        }
        walk(controller.view)
        let labels = nodes.compactMap { attribute($0,"accessibilityLabel") as? String }
        guard let node = nodes.first(where: { attribute($0,"accessibilityLabel") as? String == label }) else {
            previewFailure("Native capture control missing: \(label); \(labels)")
        }
        return node
    }
    func bool(_ node: NSObject, _ method: String) -> Bool {
        let selector=NSSelectorFromString(method)
        previewCheck(node.responds(to:selector))
        typealias Invoke = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for:selector),to:Invoke.self)(node,selector)
    }
    previewCheck(bool(find("Record dictation"),"accessibilityPerformPress") && recordings == 1)
    previewCheck(bool(find("Start meeting"),"accessibilityPerformPress") && meetings == 1)
    state.meetingCapturing = true
    previewCheck(!bool(find("Record dictation"),"isAccessibilityEnabled"), "Meeting must disable dictation action")
    state.meetingCapturing = false; state.capturing = true
    previewCheck(!bool(find("Start meeting"),"isAccessibilityEnabled"), "Dictation must disable meeting action")
    previewCheck(bool(find("Stop recording"),"accessibilityPerformPress") && recordings == 2)
    state.capturing = false; state.captureMode = .prompt
    previewCheck(bool(find("Record prompt"),"accessibilityPerformPress") && recordings == 3)
    previewCheck(bool(find("Import a recording…"),"accessibilityPerformPress") && imports == 1)
    state.importing = true
    previewCheck(!bool(find("Import a recording…"),"isAccessibilityEnabled"))
    previewCheck(bool(find("Cancel import"),"accessibilityPerformPress") && cancels == 1)
    previewCheck(bool(find("Open Inbox"),"accessibilityPerformPress") && nav.section == .inbox)
    print("NATIVE CAPTURE PASS: real accessible recording/prompt/meeting actions, mutual exclusion, import/cancel, Inbox navigation; callbacks isolated")
}
