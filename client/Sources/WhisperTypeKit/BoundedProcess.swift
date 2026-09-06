import Foundation
import Darwin

/// Both pipes are drained even when diagnostics exceed the retained limit.
public enum BoundedProcess {
    public struct Output { public let data: Data; public let diagnostics: String }
    private final class Buffer {
        let lock = NSLock()
        var data = Data()
        func append(_ bytes: Data, limit: Int) {
            lock.lock(); defer { lock.unlock() }
            data.append(bytes.prefix(max(0, limit - data.count)))
        }
    }
    public static func run(executable: URL, arguments: [String], timeout: TimeInterval = 600,
                           maxOutput: Int = 1_024 * 1_024 * 1_024,
                           isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> Output {
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = stdout; process.standardError = stderr
        let output = Buffer(), diagnostic = Buffer(), group = DispatchGroup()
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        for (pipe, buffer, limit) in [(stdout, output, maxOutput + 1), (stderr, diagnostic, 65536)] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave(); try? pipe.fileHandleForReading.close() }
                while true {
                    let bytes = pipe.fileHandleForReading.availableData
                    if bytes.isEmpty { break }
                    buffer.append(bytes, limit: limit)
                }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var finished = false
        while Date() < deadline && !isCancelled() {
            if ended.wait(timeout: .now() + 0.05) == .success { finished = true; break }
        }
        let cancelled = isCancelled()
        let timedOut = !finished && !cancelled
        if !finished {
            process.terminate()
            if ended.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        guard group.wait(timeout: .now() + 5) == .success else {
            throw CocoaError(.fileReadUnknown)
        }
        if cancelled { throw CancellationError() }
        if timedOut { throw URLError(.timedOut) }
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "voice.convert", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(data: diagnostic.data, encoding: .utf8) ?? "Conversion failed. Original recording retained."])
        }
        guard output.data.count <= maxOutput else { throw CocoaError(.fileReadTooLarge) }
        return Output(data: output.data, diagnostics: String(data: diagnostic.data, encoding: .utf8) ?? "")
    }
}
