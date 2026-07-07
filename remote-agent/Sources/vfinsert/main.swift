import Foundation
import Network
import ApplicationServices

// WhisperType remote insertion agent.
//
// Runs on the Mac Mini as a GUI-session LaunchAgent. Receives a transcript over
// the local network and types it LOCALLY (where modifier keys work),
// so dictation from a Home-Mac client inserts correctly into the Mini's focused
// field — the field you see over Screen Sharing. This is the piece that beats
// the VNC modifier boundary: insertion happens on the far side of it.
//
//   POST /insert   {"text": "..."}   -> types it, returns "ok"
//   GET  /health                     -> {"status":"ok"}
//
// Env: VF_AGENT_PORT (default 8791)

let PORT = UInt16(ProcessInfo.processInfo.environment["VF_AGENT_PORT"] ?? "8791") ?? 8791

func log(_ s: String) {
    FileHandle.standardOutput.write("\(ISO8601DateFormatter().string(from: Date())) \(s)\n".data(using: .utf8)!)
}

// Warn (don't block) if Accessibility isn't granted yet.
if !AXIsProcessTrusted() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    log("WARNING: Accessibility not granted — grant vfinsert in Privacy & Security > Accessibility, then it will type.")
}

final class Connection {
    let conn: NWConnection
    var buffer = Data()
    var onDone: (() -> Void)?
    init(_ c: NWConnection) { conn = c }

    func finish() {
        conn.cancel()
        onDone?()
        onDone = nil
    }

    func start() {
        conn.start(queue: .main)
        read()
    }

    func read() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data { self.buffer.append(data) }
            if self.tryHandle() { return }
            if error == nil && !isComplete { self.read() } else { self.finish() }
        }
    }

    /// Returns true once a complete request has been handled (and response sent).
    func tryHandle() -> Bool {
        guard let sep = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let headerData = buffer.subdata(in: 0..<sep.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else { conn.cancel(); return true }
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestLine = lines.first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1]) : "/"

        var contentLength = 0
        for line in lines.dropFirst() {
            let l = line.lowercased()
            if l.hasPrefix("content-length:") {
                contentLength = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = sep.upperBound
        let available = buffer.count - bodyStart
        if available < contentLength { return false } // wait for full body

        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))

        switch (method, path) {
        case ("GET", "/health"):
            respond(200, "{\"status\":\"ok\"}")
        case ("POST", "/insert"):
            let text = parseText(body)
            log("insert \(text.count) chars")
            DispatchQueue.main.async { Inserter.type(text) }
            respond(200, "ok")
        default:
            respond(404, "not found")
        }
        return true
    }

    func parseText(_ body: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let t = obj["text"] as? String {
            return t
        }
        return String(data: body, encoding: .utf8) ?? ""
    }

    func respond(_ code: Int, _ body: String) {
        let payload = Data(body.utf8)
        let resp = "HTTP/1.1 \(code) OK\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        var out = Data(resp.utf8); out.append(payload)
        conn.send(content: out, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }
}

let params = NWParameters.tcp
params.allowLocalEndpointReuse = true
guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: PORT)!) else {
    log("FATAL: cannot bind port \(PORT)"); exit(1)
}
// Retain active connections so ARC doesn't deallocate them mid-request.
var activeConns: [ObjectIdentifier: Connection] = [:]
listener.newConnectionHandler = { nwConn in
    let c = Connection(nwConn)
    let id = ObjectIdentifier(c)
    activeConns[id] = c
    c.onDone = { activeConns[id] = nil }
    c.start()
}
listener.start(queue: .main)
log("vfinsert listening on :\(PORT)  (accessibility trusted: \(AXIsProcessTrusted()))")

// Keep the run loop alive.
RunLoop.main.run()
