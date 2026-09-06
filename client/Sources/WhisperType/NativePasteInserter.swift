import AppKit
import Carbon

/// One local paste transaction. AX text/selection are optional receipts; they
/// do not decide whether a normal app can receive the user's paste command.
enum NativePasteInserter {
    struct ClipboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        init?(_ board: NSPasteboard) {
            var saved: [[NSPasteboard.PasteboardType: Data]] = []
            for item in board.pasteboardItems ?? [] {
                var types: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    guard let data = item.data(forType: type) else { return nil }
                    types[type] = data
                }
                saved.append(types)
            }
            items = saved
        }
        func restore(_ board: NSPasteboard) {
            let restored = items.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            board.clearContents()
            if !restored.isEmpty { board.writeObjects(restored) }
        }
    }

    @MainActor static func paste(_ text: String, targetPID: pid_t,
                                 board: NSPasteboard = .general,
                                 isCurrent: () -> Bool,
                                 send: ((pid_t) -> Bool)? = nil) async -> Bool {
        guard !text.isEmpty, isCurrent(), !IsSecureEventInputEnabled(),
              let saved = ClipboardSnapshot(board) else { return false }
        let clearedChange = board.clearContents()
        guard board.setString(text, forType: .string) else {
            if board.changeCount == clearedChange { saved.restore(board) }
            return false
        }
        let ownedChange = board.changeCount
        defer {
            // A new user/app copy owns the clipboard now. Never overwrite it.
            if board.changeCount == ownedChange { saved.restore(board) }
        }
        guard isCurrent(), !IsSecureEventInputEnabled() else { return false }
        guard (send ?? postPaste)(targetPID) else { return false }
        // Give the target event loop time to consume the clipboard. This is not
        // a receipt wait; an unreadable field does not incur further polling.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { continuation.resume() }
        }
        return true
    }

    private static func postPaste(_ pid: pid_t) -> Bool {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(pid); up.postToPid(pid)
        return true
    }
}
