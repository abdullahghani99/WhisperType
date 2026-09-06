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

    static func capture() -> CaptureDestination? {
        guard AXIsProcessTrusted() else { return nil }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &focused) == .success,
              let focused = focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused as! AXUIElement, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        func attribute(_ object: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(object, name as CFString, &value) == .success else { return nil }
            return value
        }
        guard let winValue = attribute(element, kAXFocusedWindowAttribute),
              CFGetTypeID(winValue) == AXUIElementGetTypeID(),
              let fieldValue = attribute(element, kAXFocusedUIElementAttribute),
              CFGetTypeID(fieldValue) == AXUIElementGetTypeID() else { return nil }
        let window = winValue as! AXUIElement, field = fieldValue as! AXUIElement
        let remote = (app.bundleIdentifier ?? "").contains("ScreenSharing")
        let role = attribute(field, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(field, kAXSubroleAttribute) as? String ?? ""
        var writable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &writable)
        guard remote || ((writable.boolValue || [kAXTextFieldRole, kAXTextAreaRole].contains(role)) && subrole != kAXSecureTextFieldSubrole) else { return nil }
        return CaptureDestination(app: app, window: window, field: field,
                                  title: attribute(window, kAXTitleAttribute) as? String ?? "")
    }
    func isCurrent() -> Bool {
        guard let current = Self.capture() else { return false }
        return app.processIdentifier == current.app.processIdentifier &&
            CFEqual(window, current.window) && CFEqual(field, current.field) && title == current.title
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
