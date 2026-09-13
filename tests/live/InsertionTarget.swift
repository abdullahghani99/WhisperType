import AppKit

/// A minimal destination application for the end-to-end acceptance test.
///
/// The harness needs a REAL other process to insert into: `CaptureDestination`
/// deliberately refuses its own process, and pasting into the speaker's own
/// TextEdit document would put test text in a file they own. This is an ordinary
/// AppKit app with an ordinary text view, so the accessibility tree, the focus
/// behaviour and the paste handling are the system's, not a simulation.
///
/// It prints READY on stdout once its window is key, then exits when its text
/// is read back or on SIGTERM.
final class Target: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var text: NSTextView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 520, height: 220),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WhisperType insertion target"
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        text = NSTextView(frame: scroll.bounds)
        text.isEditable = true
        text.isRichText = false
        scroll.documentView = text
        scroll.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(scroll)
        // A real Edit menu, because Cmd+V is a menu key equivalent: without one
        // the paste has nowhere to route and the text view stays empty, which
        // would look exactly like the insertion path being broken.
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        // A ready FILE, not a pipe: the driver must be able to give up on a
        // deadline, and reading a pipe blocks it with no way to do that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let pid = String(ProcessInfo.processInfo.processIdentifier)
            if CommandLine.arguments.count > 1 {
                try? pid.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
            }
            print("READY \(pid)"); fflush(stdout)
        }
    }
}

let app = NSApplication.shared
let delegate = Target()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
