import AppKit
import WebKit

/// Own controls and an isolated clipboard exercise paste/receipt behavior without
/// foreground activation, microphone use or events sent to another application.
func testNativePasteInteraction() {
    var finished = false
    Task { @MainActor in
        let board = NSPasteboard(name: .init("whispertype.paste.test." + UUID().uuidString))
        defer { board.releaseGlobally(); finished = true }
        let custom = NSPasteboard.PasteboardType("test.binary")
        let item = NSPasteboardItem(); item.setString("original", forType: .string); item.setData(Data([0, 7, 255]), forType: custom)
        board.writeObjects([item])
        var delivered = ""
        let sent = await NativePasteInserter.paste("replacement", targetPID: getpid(), board: board, isCurrent: { true }, send: { _ in
            delivered = board.string(forType: .string) ?? ""; return true
        })
        previewCheck(sent && delivered == "replacement", "Paste command must receive the owned text")
        previewCheck(board.string(forType: .string) == "original" && board.data(forType: custom) == Data([0, 7, 255]), "Restore every clipboard type")
        var validations = 0; var invoked = false
        let cancelled = await NativePasteInserter.paste("cancel", targetPID: getpid(), board: board, isCurrent: { validations += 1; return validations == 1 }, send: { _ in invoked = true; return true })
        previewCheck(!cancelled && !invoked && board.string(forType: .string) == "original", "Changed target cancels before paste and restores clipboard")
        _ = await NativePasteInserter.paste("owned", targetPID: getpid(), board: board, isCurrent: { true }, send: { _ in
            board.clearContents(); board.setString("new user copy", forType: .string); return true
        })
        previewCheck(board.string(forType: .string) == "new user copy", "Never restore over a newer copy")

        let panel = NSPanel(contentRect: NSRect(x: 80, y: 80, width: 400, height: 180), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let editor = NSTextView(frame: panel.contentView!.bounds)
        panel.contentView = editor; panel.orderBack(nil)
        defer { panel.orderOut(nil); panel.close() }
        editor.string = "Before old after"; editor.setSelectedRange(NSRange(location: 7, length: 3))
        let text = "Hello 🌍\nSecond line"
        let native = await NativePasteInserter.paste(text, targetPID: getpid(), isCurrent: { true }, send: { _ in editor.paste(nil); return true })
        previewCheck(native && editor.string == "Before " + text + " after", "Native text paste preserves selection, Unicode and newlines")

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        panel.contentView = web
        web.loadHTMLString("<html><body><textarea id='editor'>Before old after</textarea></body></html>", baseURL: nil)
        do {
            var ready = false
            for _ in 0..<50 {
                if (try? await web.evaluateJavaScript("!!document.getElementById('editor')")) as? Bool == true { ready = true; break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            previewCheck(ready, "Own browser editor must load")
            _ = try await web.evaluateJavaScript("var e=document.getElementById('editor');e.focus();e.setSelectionRange(7,10)")
            let pasted = await NativePasteInserter.paste(text, targetPID: getpid(), isCurrent: { true }, send: { _ in
                web.tryToPerform(#selector(NSText.paste(_:)), with: nil)
            })
            let actual = try await web.evaluateJavaScript("document.getElementById('editor').value") as? String
            previewCheck(pasted && actual == "Before " + text + " after", "Browser framework must accept the native paste with an independent DOM receipt")
        } catch { previewFailure("Native browser paste failed: \(error)") }
        print("NATIVE PASTE PASS: AppKit and WebKit independent receipts, Unicode/multiline/selection, all-type clipboard restoration, ownership change, cancelled target; no external events")
    }
    let deadline = Date().addingTimeInterval(20)
    while !finished && Date() < deadline { pumpPreviewEvents(until: Date().addingTimeInterval(0.05)) }
    previewCheck(finished, "Native paste test timed out")
}
