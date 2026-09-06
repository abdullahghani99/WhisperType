import Foundation
import CryptoKit

struct AgentFailure: Error {
    let code: Int
    let message: String
}

struct AgentRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

enum AgentProtocol {
    static let maximumHeader = 16_384
    static let maximumBody = 262_144

    /// One bounded, unambiguous HTTP request per connection. Chunking and
    /// pipelining are deliberately unsupported by this small paired endpoint.
    static func parse(_ buffer: Data) throws -> AgentRequest? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > maximumHeader { throw AgentFailure(code: 431, message: "Header too large") }
            return nil
        }
        guard separator.lowerBound <= maximumHeader,
              let header = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else {
            throw AgentFailure(code: 400, message: "Invalid header")
        }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/") else {
            throw AgentFailure(code: 400, message: "Invalid request line")
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                throw AgentFailure(code: 400, message: "Invalid header field")
            }
            let name = line[..<colon].lowercased()
            guard name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }), fields[name] == nil else {
                throw AgentFailure(code: 400, message: "Duplicate or invalid header")
            }
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["transfer-encoding"] == nil else { throw AgentFailure(code: 400, message: "Chunking unsupported") }
        let length: Int
        if let raw = fields["content-length"] {
            guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(raw), value <= maximumBody else {
                throw AgentFailure(code: 413, message: "Invalid or oversized body")
            }
            length = value
        } else {
            guard first[0] != "POST" else { throw AgentFailure(code: 411, message: "Content-Length required") }
            length = 0
        }
        let available = buffer.count - separator.upperBound
        guard available <= length else { throw AgentFailure(code: 400, message: "Unexpected trailing data") }
        guard available == length else { return nil }
        return AgentRequest(method: String(first[0]), path: String(first[1]), headers: fields,
                            body: buffer.subdata(in: separator.upperBound..<buffer.endIndex))
    }

    static func authorize(_ header: String?, key: String) throws {
        guard key.utf8.count >= 32 else { throw AgentFailure(code: 503, message: "Agent is unpaired; configure a key of at least 32 bytes") }
        let expected = Array(SHA256.hash(data: Data("Bearer \(key)".utf8)))
        let supplied = Array(SHA256.hash(data: Data((header ?? "").utf8)))
        let difference = zip(expected, supplied).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard difference == 0 else { throw AgentFailure(code: 401, message: "Pairing key rejected") }
    }

    static func payload(_ data: Data, requiresText: Bool) throws -> (UUID, String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = object["id"] as? String, let id = UUID(uuidString: rawID) else {
            throw AgentFailure(code: 422, message: "A UUID request id is required")
        }
        let text = object["text"] as? String ?? ""
        if requiresText && (text.isEmpty || text.count > 16_000 || text.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\r" })) {
            throw AgentFailure(code: 422, message: "Text must contain 1–16000 characters without control keys")
        }
        return (id, text)
    }
}

/// Persist only a text hash and receipt, never the transcript. A reservation is
/// synced BEFORE any key events. An interrupted operation is never replayed.
final class InsertionLedger {
    struct Receipt: Codable { let digest: String; var state: String; let created: Date }
    let root: URL
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func url(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
    private func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    func existing(_ id: UUID, text: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: url(id).path) else { return nil }
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url(id)))
        guard receipt.digest == digest(text) else { throw AgentFailure(code: 409, message: "Request id already belongs to different text") }
        return receipt.state
    }
    func reserve(_ id: UUID, text: String) throws {
        guard try existing(id, text: text) == nil else { throw AgentFailure(code: 409, message: "Request already reserved") }
        try save(Receipt(digest: digest(text), state: "uncertain", created: Date()), id: id)
    }
    func complete(_ id: UUID, text: String, verified: Bool = false) throws {
        guard try existing(id, text: text) == "uncertain" else { throw AgentFailure(code: 409, message: "Missing insertion reservation") }
        try save(Receipt(digest: digest(text), state: verified ? "verified" : "posted", created: Date()), id: id)
    }
    private func save(_ receipt: Receipt, id: UUID) throws {
        let path = url(id)
        try JSONEncoder().encode(receipt).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.synchronize()
        let directory = open(root.path, O_RDONLY)
        guard directory >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
