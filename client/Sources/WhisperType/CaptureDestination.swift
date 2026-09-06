import AppKit
import ApplicationServices

/// Ephemeral identity of the application, window and focused field at capture.
/// Persisted recovery never auto-types after restart: the user reviews placement.
struct CaptureDestination {
    let app: NSRunningApplication
    let window: AXUIElement
    let field: AXUIElement
    let title: String
    var name: String { app.localizedName ?? "application" }
    var isRemote: Bool { (app.bundleIdentifier ?? "").contains("ScreenSharing") }

    static func capture(diagnose: (String) -> Void = { _ in }) -> CaptureDestination? {
        guard AXIsProcessTrusted() else { diagnose("accessibility-denied"); return nil }
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &focused)
        guard status == .success, let focused = focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            diagnose("focused-application-unavailable ax=\(status.rawValue)"); return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused as! AXUIElement, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid) else { diagnose("focused-process-unavailable"); return nil }
        guard pid != ProcessInfo.processInfo.processIdentifier else { diagnose("own-application-focused"); return nil }
        let identity = "bundle=\(app.bundleIdentifier ?? "unknown") pid=\(pid)"
        let element = AXUIElementCreateApplication(pid)
        func attribute(_ object: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(object, name as CFString, &value)
            guard result == .success else { diagnose("\(identity) attribute=\(name) ax=\(result.rawValue)"); return nil }
            return value
        }
        guard let winValue = attribute(element, kAXFocusedWindowAttribute),
              CFGetTypeID(winValue) == AXUIElementGetTypeID() else { diagnose("\(identity) focused-window-unavailable"); return nil }
        guard let fieldValue = attribute(element, kAXFocusedUIElementAttribute),
              CFGetTypeID(fieldValue) == AXUIElementGetTypeID() else { diagnose("\(identity) focused-field-unavailable"); return nil }
        let window = winValue as! AXUIElement, field = fieldValue as! AXUIElement
        let remote = (app.bundleIdentifier ?? "").contains("ScreenSharing")
        let role = attribute(field, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(field, kAXSubroleAttribute) as? String ?? ""
        var writable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &writable)
        guard remote || ((writable.boolValue || [kAXTextFieldRole, kAXTextAreaRole].contains(role)) && subrole != kAXSecureTextFieldSubrole) else {
            diagnose("\(identity) field-rejected role=\(role) subrole=\(subrole) writable=\(writable.boolValue)"); return nil
        }
        diagnose("captured \(identity) role=\(role) remote=\(remote)")
        return CaptureDestination(app: app, window: window, field: field,
                                  title: attribute(window, kAXTitleAttribute) as? String ?? "")
    }
    func isCurrent(diagnose: (String) -> Void = { _ in }) -> Bool {
        guard let current = Self.capture(diagnose: diagnose) else { return false }
        guard app.processIdentifier == current.app.processIdentifier else { diagnose("application-changed"); return false }
        guard CFEqual(window, current.window) else { diagnose("window-changed"); return false }
        guard CFEqual(field, current.field) else { diagnose("field-changed"); return false }
        guard title == current.title else { diagnose("window-title-changed"); return false }
        return true
    }
    /// A receipt can verify acceptance only when the app exposes plain text and
    /// selection. Editors without these attributes still receive keys, but the
    /// recording must stay in Inbox for the user to confirm.
    func expectedValue(afterInserting text: String) -> String? {
        var value: CFTypeRef?, selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
              let before = value as? String,
              AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
              let selection = selection, CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(selection as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0,
              range.location <= (before as NSString).length,
              range.length <= (before as NSString).length - range.location else { return nil }
        return (before as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
    }
    func containsVerifiedValue(_ expected: String?) -> Bool {
        guard let expected = expected else { return false }
        var actual: CFTypeRef?
        return AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &actual) == .success && (actual as? String) == expected
    }
}
