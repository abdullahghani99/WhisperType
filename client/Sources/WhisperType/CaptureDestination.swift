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
        var axPID: pid_t?
        if status == .success, let focused = focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            var value: pid_t = 0
            if AXUIElementGetPid(focused as! AXUIElement, &value) == .success { axPID = value }
        }
        let frontmostPID = status == .noValue ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        guard let pid = resolveFocusedPID(axPID: axPID, status: status, frontmostPID: frontmostPID,
                                          ownPID: ProcessInfo.processInfo.processIdentifier),
              let app = NSRunningApplication(processIdentifier: pid) else {
            diagnose("focused-application-unavailable ax=\(status.rawValue) own=\(axPID == ProcessInfo.processInfo.processIdentifier)"); return nil
        }
        if status == .noValue { diagnose("system-focus-empty; validating-frontmost bundle=\(app.bundleIdentifier ?? "unknown") pid=\(pid)") }
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
        var fieldValue = attribute(element, kAXFocusedUIElementAttribute)
        if fieldValue == nil && requestAccessibilityTree(element, diagnose: diagnose) {
            // Chromium builds its tree on demand. Allow a short bounded initial
            // response; subsequent captures and per-key checks use the live tree.
            for _ in 0..<6 {
                Thread.sleep(forTimeInterval: 0.05)
                fieldValue = attribute(element, kAXFocusedUIElementAttribute)
                if fieldValue != nil { break }
            }
        }
        guard let fieldValue = fieldValue, CFGetTypeID(fieldValue) == AXUIElementGetTypeID() else {
            diagnose("\(identity) focused-field-unavailable"); return nil
        }
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
    /// Chromium/Electron expose their full accessibility tree only after an
    /// assistive client requests it. This enables app accessibility, never focus,
    /// field values, keyboard events or global system preferences.
    private static func requestAccessibilityTree(_ application: AXUIElement, diagnose: (String) -> Void) -> Bool {
        var enabled = false
        for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            let status = AXUIElementSetAttributeValue(application, name as CFString, kCFBooleanTrue)
            diagnose("request-accessibility-tree attribute=\(name) ax=\(status.rawValue)")
            enabled = enabled || status == .success
        }
        return enabled
    }
    /// Metadata-only support inspection. Never reads values, titles or labels.
    static func diagnoseFocusedTree(_ report: (String) -> Void) {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        func get(_ item: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(item, key as CFString, &value)
            return status == .success ? value : nil
        }
        for (name, item) in [("system", AXUIElementCreateSystemWide()), ("app", application)] {
            if let field = get(item, kAXFocusedUIElementAttribute), CFGetTypeID(field) == AXUIElementGetTypeID() {
                report("\(name)-focused role=\(get(field as! AXUIElement, kAXRoleAttribute) as? String ?? "unknown")")
            } else { report("\(name)-focused absent") }
        }
        guard let raw = get(application, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
        var queue: [(AXUIElement, Int)] = [(raw as! AXUIElement, 0)]
        var index = 0
        while index < queue.count && index < 400 {
            let (node, depth) = queue[index]; index += 1
            let role = get(node, kAXRoleAttribute) as? String ?? "unknown"
            let focused = get(node, kAXFocusedAttribute) as? Bool ?? false
            var writable = DarwinBoolean(false)
            _ = AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &writable)
            if focused || writable.boolValue || [kAXTextAreaRole, kAXTextFieldRole, "AXWebArea"].contains(role) {
                report("node=\(index) depth=\(depth) role=\(role) focused=\(focused) valueSettable=\(writable.boolValue)")
            }
            if depth < 16, let children = get(node, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(max(0, 400 - queue.count)).map { ($0, depth + 1) })
            }
        }
        report("tree nodes=\(index)")
    }
    /// AX's system-wide focused app can have no value even while an app is
    /// frontmost. Use that current app only for this exact case; its focused
    /// window and editable field must still pass every check above. Never use a
    /// previously focused app or relax permission / transport failures.
    static func resolveFocusedPID(axPID: pid_t?, status: AXError, frontmostPID: pid_t?, ownPID: pid_t) -> pid_t? {
        let candidate = status == .success ? axPID : status == .noValue ? frontmostPID : nil
        guard let pid = candidate, pid > 0, pid != ownPID else { return nil }
        return pid
    }
    /// Per-event validation keeps the captured identity instead of rediscovering
    /// the application and its editable role for every character. AX read failures
    /// still stop typing, including permission loss. Secure-field transitions are
    /// rechecked, and app/window/field/title identity must all remain unchanged.
    func isCurrent(diagnose: (String) -> Void = { _ in }) -> Bool {
        guard AXIsProcessTrusted() else { diagnose("accessibility-denied"); return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            diagnose("application-changed"); return false
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        func attribute(_ object: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(object, key as CFString, &value) == .success else { return nil }
            return value
        }
        guard let currentWindow = attribute(application, kAXFocusedWindowAttribute), CFEqual(window, currentWindow) else {
            diagnose("window-changed-or-unavailable"); return false
        }
        guard let currentField = attribute(application, kAXFocusedUIElementAttribute), CFEqual(field, currentField) else {
            diagnose("field-changed-or-unavailable"); return false
        }
        guard (attribute(window, kAXTitleAttribute) as? String ?? "") == title else {
            diagnose("window-title-changed"); return false
        }
        guard isRemote || (attribute(field, kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole else {
            diagnose("secure-field"); return false
        }
        return true
    }
    func isCurrentByRecapturing(diagnose: (String) -> Void = { _ in }) -> Bool {
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
    func receiptDiagnostic(_ expected: String?) -> String {
        guard let expected = expected else { return "expected-value-or-selection-unavailable" }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
        guard status == .success, let actual = value as? String else { return "actual-value-unavailable ax=\(status.rawValue)" }
        let before = Array(expected.utf16), after = Array(actual.utf16)
        let first = zip(before, after).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset
        return "expectedUTF16=\(before.count) actualUTF16=\(after.count) firstDifference=\(first.map(String.init) ?? "none-in-shared-prefix")"
    }
    /// Explicit support probe: reads only the captured field, reports counts and
    /// consistency flags, and never logs text, changes focus or posts events.
    func receiptShapeDiagnostic() -> String {
        func read(_ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(field, key as CFString, &value) == .success else { return nil }
            return value
        }
        guard let value = read(kAXValueAttribute) as? String else { return "value-unavailable" }
        let ns = value as NSString
        var result = "valueUTF16=\(ns.length) lineBreaks=\(value.filter { $0 == "\n" || $0 == "\r" }.count) nonbreakingSpaces=\(value.filter { $0 == "\u{00A0}" }.count)"
        guard let selection = read(kAXSelectedTextRangeAttribute), CFGetTypeID(selection) == AXValueGetTypeID() else { return result + " selection-unavailable" }
        var range = CFRange()
        guard AXValueGetValue(selection as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0,
              range.location <= ns.length, range.length <= ns.length - range.location else { return result + " selection-outside-value" }
        result += " selectionOffset=\(range.location) selectionLength=\(range.length)"
        if let selected = read(kAXSelectedTextAttribute) as? String {
            result += " selectionMatchesValue=\(ns.substring(with: NSRange(location: range.location, length: range.length)) == selected)"
        }
        return result
    }
    func containsVerifiedValue(_ expected: String?) -> Bool {
        guard let expected = expected else { return false }
        var actual: CFTypeRef?
        return AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &actual) == .success && (actual as? String) == expected
    }
}
