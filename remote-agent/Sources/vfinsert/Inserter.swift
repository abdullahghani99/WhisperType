import CoreGraphics
import Carbon
import Foundation

/// Local keystroke insertion for the machine this agent runs on (the Mac Mini).
///
/// Because this types LOCALLY — not across a Screen Sharing boundary — synthetic
/// modifier flags work normally (the local app reads the event's own flags). So
/// this is the simple, fast path: keycode + flags, no HID-modifier-state dance.
enum Inserter {
    private static var keyMap: [Character: (CGKeyCode, CGEventFlags)] = buildKeyMap()

    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        for ch in text {
            if ch == "\n" || ch == "\r" {
                // Shift+Return = soft newline (plain Return submits in chat apps).
                post(CGKeyCode(kVK_Return), flags: .maskShift, source: src)
            } else if let (code, flags) = keyMap[ch] {
                post(code, flags: flags, source: src)
            } else if let special = specialKeycode(ch) {
                post(special, flags: [], source: src)
            } else {
                postUnicode(ch, source: src)
            }
            usleep(1500)
        }
    }

    private static func post(_ code: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private static func postUnicode(_ ch: Character, source: CGEventSource?) {
        let utf16 = Array(String(ch).utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private static func specialKeycode(_ ch: Character) -> CGKeyCode? {
        switch ch {
        case "\n", "\r": return CGKeyCode(kVK_Return)
        case "\t": return CGKeyCode(kVK_Tab)
        case " ": return CGKeyCode(kVK_Space)
        default: return nil
        }
    }

    private static func buildKeyMap() -> [Character: (CGKeyCode, CGEventFlags)] {
        var map: [Character: (CGKeyCode, CGEventFlags)] = [:]
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return map }
        let layoutData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let combos: [(UInt32, CGEventFlags)] = [
            (0, []),
            (UInt32(shiftKey >> 8), .maskShift),
            (UInt32(optionKey >> 8), .maskAlternate),
            (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate]),
        ]
        let kbType = UInt32(LMGetKbdType())
        layoutData.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for code in 0..<CGKeyCode(128) {
                for (mods, flags) in combos {
                    var dead: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var len = 0
                    let st = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), mods, kbType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars)
                    guard st == noErr, len > 0 else { continue }
                    let s = String(utf16CodeUnits: chars, count: len)
                    guard s.count == 1, let ch = s.first, !ch.isWhitespace else { continue }
                    if map[ch] == nil { map[ch] = (code, flags) }
                }
            }
        }
        return map
    }
}
