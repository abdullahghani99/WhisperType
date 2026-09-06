import Foundation

@main struct AgentTests {
    static func main() throws {
        var count = 0
        func rejects(_ code: Int, _ action: () throws -> Void) {
            do { try action(); fatalError("Expected rejection \(code)") }
            catch let failure as AgentFailure { precondition(failure.code == code, "\(failure)"); count += 1 }
            catch { fatalError("Unexpected error \(error)") }
        }
        let valid = Data("POST /insert HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8)
        for length in 0..<valid.count { let partial = try AgentProtocol.parse(Data(valid.prefix(length))); precondition(partial == nil); count += 1 }
        let parsed = try AgentProtocol.parse(valid)!
        precondition(parsed.path == "/insert" && parsed.body == Data("{}".utf8)); count += 1
        for raw in ["-1", "+1", "x", "9999999999999999999999999", "262145"] {
            rejects(413) { _ = try AgentProtocol.parse(Data("POST /insert HTTP/1.1\r\nContent-Length: \(raw)\r\n\r\n".utf8)) }
        }
        rejects(411) { _ = try AgentProtocol.parse(Data("POST /insert HTTP/1.1\r\n\r\n".utf8)) }
        rejects(400) { _ = try AgentProtocol.parse(Data("GET /health HTTP/1.1\r\nContent-Length: 0\r\ncontent-length: 0\r\n\r\n".utf8)) }
        rejects(400) { _ = try AgentProtocol.parse(Data("POST /insert HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) }
        rejects(400) { _ = try AgentProtocol.parse(valid + Data("trailing".utf8)) }
        rejects(431) { _ = try AgentProtocol.parse(Data(repeating: 65, count: 16_385)) }
        let key = String(repeating: "x", count: 32)
        rejects(503) { try AgentProtocol.authorize(nil, key: "") }
        rejects(401) { try AgentProtocol.authorize(nil, key: key) }
        rejects(401) { try AgentProtocol.authorize("Bearer wrong", key: key) }
        try AgentProtocol.authorize("Bearer \(key)", key: key); count += 1
        rejects(422) { _ = try AgentProtocol.payload(Data("plain text".utf8), requiresText: true) }
        let id = UUID()
        for text in ["", "tab\t", "escape\u{1b}", String(repeating: "a", count: 16_001)] {
            let data = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "text": text])
            rejects(422) { _ = try AgentProtocol.payload(data, requiresText: true) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try InsertionLedger(root: root)
        try ledger.reserve(id, text: "Private sentence")
        let restarted = try InsertionLedger(root: root)
        let uncertain = try restarted.existing(id, text: "Private sentence")
        precondition(uncertain == "uncertain"); count += 1
        rejects(409) { try restarted.reserve(id, text: "Private sentence") }
        rejects(409) { _ = try restarted.existing(id, text: "Changed sentence") }
        try restarted.complete(id, text: "Private sentence")
        let posted = try InsertionLedger(root: root).existing(id, text: "Private sentence")
        precondition(posted == "posted"); count += 1
        let receipt = try String(contentsOf: root.appendingPathComponent(id.uuidString).appendingPathExtension("json"), encoding: .utf8)
        precondition(!receipt.contains("Private sentence")); count += 1
        print("Agent protocol: \(count) checks passed; malformed framing, auth, bounded text and durable replay protection")
    }
}
