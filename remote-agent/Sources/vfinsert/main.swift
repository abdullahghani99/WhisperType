import Foundation
import Network
import ApplicationServices

let environment = ProcessInfo.processInfo.environment
let port = UInt16(environment["VF_AGENT_PORT"] ?? "8791") ?? 8791
let host = environment["VF_AGENT_HOST"] ?? "127.0.0.1"
let pairingKey = environment["VF_AGENT_KEY"] ?? ""
let dataRoot = environment["VF_AGENT_DATA_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WhisperType/InsertionReceipts")
func log(_ message: String) { print("\(ISO8601DateFormatter().string(from: Date())) \(message)") }

// Permission prompts are an explicit setup action, never a surprise at startup.
if CommandLine.arguments.contains("--request-accessibility") {
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    exit(AXIsProcessTrusted() ? 0 : 1)
}
let ledger: InsertionLedger
do { ledger = try InsertionLedger(root: dataRoot) }
catch { log("FATAL: cannot open insertion receipts: \(error.localizedDescription)"); exit(1) }
Inserter.prepare()
struct PreparedTarget { let target: CaptureDestination; let expires: Date }
var targets: [UUID: PreparedTarget] = [:] // Main queue owns all protocol state.
var insertionBusy = false
let insertionQueue = DispatchQueue(label: "vf.agent.insertion")

final class Connection {
    let conn: NWConnection
    var buffer = Data()
    var onDone: (() -> Void)?
    var deadline: DispatchWorkItem?
    var finished = false
    init(_ conn: NWConnection) { self.conn = conn }
    func finish() {
        guard !finished else { return }; finished = true
        deadline?.cancel(); conn.cancel(); onDone?(); onDone = nil
    }
    func start() {
        conn.start(queue: .main)
        let timeout = DispatchWorkItem { [weak self] in self?.respond(408, ["detail": "Request timed out"]) }
        deadline = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        read()
    }
    func read() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self = self, !self.finished else { return }
            if let data = data { self.buffer.append(data) }
            do {
                if let request = try AgentProtocol.parse(self.buffer) {
                    self.deadline?.cancel(); self.handle(request); return
                }
            } catch let failure as AgentFailure {
                self.respond(failure.code, ["detail": failure.message]); return
            } catch { self.respond(400, ["detail": "Invalid request"]); return }
            if error == nil && !complete { self.read() } else { self.finish() }
        }
    }
    func handle(_ request: AgentRequest) {
        if request.method == "GET" && request.path == "/health" {
            respond(200, ["status": "ok", "paired": pairingKey.utf8.count >= 32, "accessibility": AXIsProcessTrusted(), "release": environment["VF_AGENT_RELEASE"] ?? "development"]); return
        }
        do {
            try AgentProtocol.authorize(request.headers["authorization"], key: pairingKey)
            guard request.method == "POST", request.path == "/prepare" || request.path == "/insert" else {
                throw AgentFailure(code: 404, message: "Unknown endpoint")
            }
            let (id, text) = try AgentProtocol.payload(request.body, requiresText: request.path == "/insert")
            if request.path == "/insert", let receipt = try ledger.existing(id, text: text) {
                if receipt == "posted" || receipt == "verified" { respond(200, ["status": "posted", "id": id.uuidString, "replayed": true, "verified": receipt == "verified"]); return }
                throw AgentFailure(code: 409, message: "Previous insertion may be partial. Inspect the destination; this request will not be repeated.")
            }
            guard AXIsProcessTrusted() else { throw AgentFailure(code: 403, message: "Allow Accessibility on the paired Mac before inserting") }
            guard !insertionBusy else { throw AgentFailure(code: 409, message: "The paired Mac is currently inserting another result") }
            targets = targets.filter { $0.value.expires > Date() }
            if request.path == "/prepare" {
                if targets[id] == nil {
                    guard targets.count < 256 else { throw AgentFailure(code: 429, message: "Too many prepared destinations") }
                    guard let target = CaptureDestination.capture(), !target.isRemote else { throw AgentFailure(code: 409, message: "Focus an editable destination on the paired Mac") }
                    targets[id] = PreparedTarget(target: target, expires: Date().addingTimeInterval(900))
                }
                respond(200, ["status": "prepared", "id": id.uuidString, "application": targets[id]!.target.name]); return
            }
            guard let prepared = targets[id], prepared.target.isCurrent() else {
                throw AgentFailure(code: 409, message: "Remote destination changed or expired. Review the result before placing it.")
            }
            try ledger.reserve(id, text: text) // Durable acceptance precedes all key events.
            let expected = prepared.target.expectedValue(afterInserting: text)
            targets[id] = nil; insertionBusy = true
            insertionQueue.async { [self] in
                let posted = Inserter.type(text, targetPID: prepared.target.app.processIdentifier) {
                    DispatchQueue.main.sync { AXIsProcessTrusted() && prepared.target.isCurrent() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    insertionBusy = false
                    guard posted else {
                        self.respond(409, ["detail": "Destination changed during insertion. Some text may have been sent; inspect before retrying."]); return
                    }
                    do {
                        let verified = prepared.target.containsVerifiedValue(expected)
                        try ledger.complete(id, text: text, verified: verified)
                        self.respond(200, ["status": "posted", "id": id.uuidString, "replayed": false, "verified": verified])
                    } catch {
                        self.respond(507, ["detail": "Keys were posted but the receipt could not be saved. Inspect the destination; do not repeat automatically."])
                    }
                }
            }
        } catch let failure as AgentFailure { respond(failure.code, ["detail": failure.message]) }
        catch { respond(507, ["detail": "Cannot save insertion receipt; nothing new was typed"]) }
    }
    func respond(_ code: Int, _ object: [String: Any]) {
        guard !finished else { return }
        deadline?.cancel()
        let payload = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        var response = Data("HTTP/1.1 \(code) Response\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(payload)
        conn.send(content: response, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }
}

let parameters = NWParameters.tcp
parameters.allowLocalEndpointReuse = true
parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
let listener: NWListener
do { listener = try NWListener(using: parameters) }
catch { log("FATAL: cannot create listener: \(error.localizedDescription)"); exit(1) }
var activeConnections: [ObjectIdentifier: Connection] = [:]
listener.newConnectionHandler = { connection in
    guard activeConnections.count < 32 else { connection.cancel(); return }
    let client = Connection(connection), id = ObjectIdentifier(connection)
    activeConnections[id] = client
    client.onDone = { activeConnections[id] = nil }
    client.start()
}
listener.stateUpdateHandler = { state in
    switch state {
    case .ready: log("Agent listening on \(host):\(port); paired=\(pairingKey.utf8.count >= 32), accessibility=\(AXIsProcessTrusted())")
    case .failed(let error): log("FATAL: listener failed: \(error.localizedDescription)"); exit(1)
    default: break
    }
}
listener.start(queue: .main)
RunLoop.main.run()
