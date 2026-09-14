import AppKit
import ApplicationServices

/// The acceptance test that was never run: real speech in, real text on screen.
///
/// Every previous release was certified by unit tests and a server health check.
/// Nothing exercised the path the speaker actually uses -- audio to the server,
/// transcription, polishing, and the result landing in another application --
/// because that was assumed to need a human at a microphone. It does not:
/// macOS synthesises the speech, and an ordinary AppKit process receives the
/// insertion, so the whole loop runs unattended.
///
/// What this proves: the server transcribes and polishes real audio, the local
/// insertion transaction completes against a real accessibility tree, and the
/// text that arrives is the text that was sent. It also measures the wall clock
/// the speaker actually waits, which nothing else did.
///
/// What it does NOT prove: microphone capture (no device is opened), and Screen
/// Sharing insertion, which needs the paired agent on a second Mac.
@MainActor
enum Acceptance {
    static func fail(_ message: String) -> Never {
        print("  FAIL  \(message)")
        exit(1)
    }

    static func run() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4 else { fail("usage: acceptance <wav> <server-url> <target-binary>") }
        let wavPath = arguments[1], server = arguments[2], targetPath = arguments[3]
        guard AXIsProcessTrusted() else {
            fail("Accessibility is not granted to this process. Grant it to the terminal running the test.")
        }
        guard let wav = try? Data(contentsOf: URL(fileURLWithPath: wavPath)) else { fail("cannot read \(wavPath)") }

        // ---- 1. a real destination application, before any timing
        // Launched through LaunchServices, not spawned directly: a process the
        // window server did not register never becomes the frontmost
        // application, and the focused-application query then returns nothing.
        let readyFile = NSTemporaryDirectory() + "vf-target-\(UUID().uuidString).pid"
        let bundle = URL(fileURLWithPath: targetPath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-n", "-a", bundle.path, "--args", readyFile]
        guard (try? launcher.run()) != nil else { fail("could not launch the insertion target") }
        launcher.waitUntilExit()
        defer {
            try? FileManager.default.removeItem(atPath: readyFile)
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.whispertype.test.insertiontarget")
                .forEach { $0.forceTerminate() }
        }
        var targetPID: pid_t = 0
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, targetPID == 0 {
            if let text = try? String(contentsOfFile: readyFile, encoding: .utf8),
               let found = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { targetPID = found }
            else { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        guard targetPID != 0 else { fail("the insertion target never became ready") }
        // Let the window server settle the focus change before asking who is
        // focused, and make sure the target really is frontmost first.
        for _ in 0..<20 {
            if let app = NSRunningApplication(processIdentifier: targetPID) {
                if app.isActive { break }
                app.activate(options: [.activateIgnoringOtherApps])
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID {
            print("  note     : frontmost is \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown")")
        }

        // ---- 2. the server leg
        //
        // Timed only after the destination exists. An earlier version started
        // the clock here and launched the target afterwards, so the "total"
        // swallowed app launch plus fixed 800 ms and 400 ms settle waits, and
        // the remainder was reported as client overhead. It was test setup.
        // What `server` measures is the HTTP round trip -- upload, inference and
        // download together -- not isolated server compute.
        let boundary = "vf-acceptance-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: server)!.appendingPathComponent("dictate"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = AudioUpload.multipart(wav: wav, boundary: boundary)
        let started = Date()
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            fail("the server did not accept the dictation")
        }
        let serverMs = Int(Date().timeIntervalSince(started) * 1000)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["raw"] as? String, let polished = object["text"] as? String,
              !polished.isEmpty else { fail("the server returned no transcript") }
        print("  heard    : \(raw.prefix(140))")
        print("  polished : \(polished.prefix(140))")
        print("  server   : \(serverMs) ms round trip for \(wav.count / 1024) KB (upload + inference + download)")

        // ---- 3. the production insertion path, unchanged
        // Focus acquisition is racy: the window server can still be settling
        // when the first query lands, and the system-wide focused-application
        // attribute then reports that it cannot complete. A real dictation hits
        // the same race, which is why capture is retried rather than failed.
        var captured: CaptureDestination?
        for attempt in 0..<12 {
            NSRunningApplication(processIdentifier: targetPID)?.activate(options: [.activateIgnoringOtherApps])
            try? await Task.sleep(nanoseconds: 400_000_000)
            captured = CaptureDestination.capture(diagnose: { if attempt == 11 { print("  note     : \($0)") } })
            if captured?.app.processIdentifier == targetPID { break }
            captured = nil
        }
        guard let destination = captured else {
            fail("no destination captured -- the target did not take focus")
        }
        guard destination.app.processIdentifier == targetPID else {
            fail("focus landed on \(destination.name), not the test target; run this with no other app stealing focus")
        }
        let before = destination.readableValue()
        let expected = destination.expectedValue(afterInserting: polished)
        let typingStarted = Date()
        let sent = await NativePasteInserter.paste(polished, targetPID: targetPID,
                                                   isCurrent: { destination.isCurrent() })
        guard sent else { fail("the insertion transaction did not complete") }
        let typingMs = Int(Date().timeIntervalSince(typingStarted) * 1000)

        // ---- 4. the receipt: what actually landed on screen
        var verified = false
        for attempt in 0...5 {
            if destination.containsVerifiedValue(expected) { verified = true; break }
            if attempt < 5 { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        let landed = destination.readableValue() ?? ""
        print("  typing   : \(typingMs) ms")
        print("  total    : \(Int(Date().timeIntervalSince(started) * 1000)) ms request-to-text-on-screen")
        print("  landed   : \(landed.prefix(140))")

        guard verified else {
            fail("the destination did not confirm the text (before=\(before ?? "nil"))")
        }
        guard landed.contains(polished) else {
            fail("what landed is not what was sent")
        }
        print("  PASS     real speech transcribed, polished, and inserted into a live application")
        exit(0)
    }
}

@main
enum Main {
    static func main() {
        Task { @MainActor in await Acceptance.run() }
        RunLoop.main.run()
    }
}
