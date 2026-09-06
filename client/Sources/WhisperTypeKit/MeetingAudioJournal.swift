import Foundation

/// Incremental, recoverable 16 kHz mono PCM. Audio callbacks enqueue bounded
/// writes; model work and HAL teardown never hold the only copy of a meeting.
public final class MeetingAudioJournal {
    public enum Track { case system, microphone }
    public let directory: URL
    public let wavURL: URL
    private let queue = DispatchQueue(label: "voice.capture.journal")
    private let lock = NSLock()
    private var queuedBytes = 0
    private var failure: Error?
    private var systemBytes = 0
    private var microphoneBytes = 0
    private var sealed = false
    private let system: FileHandle
    private let microphone: FileHandle
    private var lastSync = Date()
    public var onFailure: ((Error) -> Void)?

    public init(parent: URL, id: UUID = UUID()) throws {
        directory = parent.appendingPathComponent("capture-\(id.uuidString)", isDirectory: true)
        wavURL = parent.appendingPathComponent("meeting-\(id.uuidString).wav")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let a = directory.appendingPathComponent("system.pcm")
        let b = directory.appendingPathComponent("microphone.pcm")
        guard FileManager.default.createFile(atPath: a.path, contents: nil),
              FileManager.default.createFile(atPath: b.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        system = try FileHandle(forWritingTo: a)
        microphone = try FileHandle(forWritingTo: b)
        try Data("16 kHz, mono, signed 16-bit little-endian PCM. Recover using the app's recordings recovery.\n".utf8)
            .write(to: directory.appendingPathComponent("format.txt"), options: .atomic)
    }

    public var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    public func count(_ track: Track) -> Int {
        lock.lock(); defer { lock.unlock() }
        return track == .system ? systemBytes : microphoneBytes
    }

    public func append(_ data: Data, to track: Track) {
        lock.lock()
        guard !sealed, failure == nil else { lock.unlock(); return }
        guard queuedBytes + data.count <= 2 * 1024 * 1024 else {
            lock.unlock(); fail(CocoaError(.fileWriteOutOfSpace)); return
        }
        queuedBytes += data.count
        if track == .system { systemBytes += data.count } else { microphoneBytes += data.count }
        // Enqueue under the lock so two producers cannot reorder logical offsets.
        queue.async { [self] in
            do {
                try (track == .system ? system : microphone).write(contentsOf: data)
                if Date().timeIntervalSince(lastSync) >= 1 {
                    try system.synchronize(); try microphone.synchronize(); lastSync = Date()
                }
            } catch { fail(error) }
            lock.lock(); queuedBytes -= data.count; lock.unlock()
        }
        lock.unlock()
    }

    private func fail(_ error: Error) {
        lock.lock(); let first = failure == nil; failure = error; lock.unlock()
        if first { DispatchQueue.main.async { [weak self] in self?.onFailure?(error) } }
    }

    public func finish() throws -> Data {
        lock.lock(); sealed = true; lock.unlock()
        try queue.sync {
            try system.synchronize(); try microphone.synchronize()
            try system.close(); try microphone.close()
        }
        // Even a failed track retains its successfully written prefix on disk.
        if let error = error { throw error }
        try Self.recover(directory: directory, to: wavURL)
        try FileManager.default.removeItem(at: directory)
        return try Data(contentsOf: wavURL, options: .mappedIfSafe)
    }

    /// Also works after a terminated process: only complete int16 frames count.
    public static func recover(directory: URL, to destination: URL) throws {
        let a = try FileHandle(forReadingFrom: directory.appendingPathComponent("system.pcm"))
        let b = try FileHandle(forReadingFrom: directory.appendingPathComponent("microphone.pcm"))
        defer { try? a.close(); try? b.close() }
        let temporary = destination.appendingPathExtension("partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let out = try FileHandle(forWritingTo: temporary)
        defer { try? out.close() }
        try out.write(contentsOf: wavHeader(bytes: 0))
        var total = 0
        while true {
            let x = try a.read(upToCount: 65536) ?? Data()
            let y = try b.read(upToCount: 65536) ?? Data()
            let n = max(x.count / 2, y.count / 2)
            if n == 0 { break }
            var mixed = [Int16](repeating: 0, count: n)
            for i in 0..<n {
                func sample(_ d: Data) -> Int32 {
                    guard i * 2 + 1 < d.count else { return 0 }
                    return Int32(Int16(bitPattern: UInt16(d[i * 2]) | UInt16(d[i * 2 + 1]) << 8))
                }
                mixed[i] = Int16(clamping: sample(x) + sample(y)).littleEndian
            }
            try mixed.withUnsafeBytes { try out.write(contentsOf: Data($0)) }
            total += n * 2
            guard total <= Int(UInt32.max) - 36 else { throw CocoaError(.fileWriteOutOfSpace) }
        }
        try out.seek(toOffset: 0); try out.write(contentsOf: wavHeader(bytes: total))
        try out.synchronize(); try out.close()
        // A unique destination prevents overwriting another recovered recording.
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    public static func wavHeader(bytes: Int) -> Data {
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: s.utf8) }
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(bytes) + 36); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        text("data"); u32(UInt32(bytes)); return data
    }
}
