import Foundation

/// A recording retains its own audio and result until insertion or explicit removal.
public enum RecordingStore {
    public struct Entry: Codable, Identifiable {
        public let id: UUID
        public let created: Date
        public var kind: String
        public var status: String
        public var text: String
        public var raw: String
        public var error: String
        public var historyID: Int?
        public var variants: [String: String]
        /// True only after the complete send path finishes. Optional for legacy
        /// recordings; an interrupted or partial send must remain actionable.
        public var sendCompleted: Bool?
        /// Explicit filing only; never implies delivery or deletes saved audio.
        public var archived: Bool?
        /// True only when automatic placement was deferred before any send.
        public var placementDeferred: Bool?
        public var canInsertSavedHere: Bool {
            guard kind == "dictation", status == "ready", !isArchived,
                  !sentUnverified, sendCompleted != true, !text.isEmpty else { return false }
            if let deferred = placementDeferred { return deferred }
            // Known legacy pre-send failure; never retry a partial/unverified send.
            return error == "Destination changed. Result retained; review placement."
                || error == "Result ready. Review it in Inbox to choose placement."
        }
        public var isArchived: Bool { archived == true }
        public var hasResult: Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                variants.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        public var sentUnverified: Bool {
            status == "sent_unverified" || error.hasPrefix("Keys were sent;")
        }
        public var belongsInSentHistory: Bool {
            hasResult && sentUnverified && (sendCompleted == true || (sendCompleted == nil && error.hasPrefix("Keys were sent;")))
        }
        public var needsAttention: Bool { !isArchived && status != "inserted" && !belongsInSentHistory }
        public var inboxMessage: String {
            if sentUnverified { return "Typing was sent. Check the destination before inserting again." }

            if status == "ready" && !hasResult { return "No transcript was returned. Your audio is saved." }
            return error.isEmpty ? (hasResult ? "Ready for review" : "Audio saved") : error
        }
        public init(id: UUID = UUID(), kind: String, created: Date = Date()) {
            self.id = id; self.created = created; self.kind = kind; status = "pending"
            text = ""; raw = ""; error = ""; variants = [:]
        }
    }
    public static func recordingsDirectory() -> URL {
        let base = ProcessInfo.processInfo.environment["VF_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("WhisperType", isDirectory: true)
        return base.appendingPathComponent("Recordings", isDirectory: true)
    }
    public static func pendingDirectory() -> URL { recordingsDirectory().appendingPathComponent("pending", isDirectory: true) }
    public static func audioURL(_ id: UUID, directory: URL = pendingDirectory()) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("wav")
    }
    public static func save(_ entry: Entry, directory: URL = pendingDirectory()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(entry)
        try durableWrite(data, to: directory.appendingPathComponent(entry.id.uuidString).appendingPathExtension("json"))
    }
    public static func create(wav: Data, kind: String, id: UUID = UUID(), directory: URL = pendingDirectory()) throws -> Entry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let entry = Entry(id: id, kind: kind)
        let url = audioURL(id, directory: directory)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try durableWrite(wav, to: url)
        try save(entry, directory: directory)
        return entry
    }
    public static func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    public static func entries(directory: URL = pendingDirectory()) throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var entries = [UUID: Entry]()
        for url in files where url.pathExtension == "json" {
            if let entry = try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: url)) { entries[entry.id] = entry }
        }
        // An interrupted metadata write must not hide the surviving recording.
        for url in files where url.pathExtension == "wav" {
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), entries[id] == nil {
                var entry = Entry(id: id, kind: "dictation")
                entry.error = "Recovered audio without metadata. Choose Retry or open the recording."
                entries[id] = entry
            }
        }
        return entries.values.sorted { $0.created > $1.created }
    }
    public static func removeAudio(_ id: UUID, directory: URL = pendingDirectory()) throws {
        let url = audioURL(id, directory: directory)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public static func setArchived(_ id: UUID, _ archived: Bool, directory: URL = pendingDirectory()) throws {
        guard var entry = try entries(directory: directory).first(where: { $0.id == id }),
              entry.status != "processing" else { throw CocoaError(.fileWriteNoPermission) }
        entry.archived = archived
        try save(entry, directory: directory)
    }
    /// Recover once into local History. Originals remain in a separate folder;
    /// a retry reuses the same identity instead of generating duplicate WAVs.
    @discardableResult public static func recoverMeetingToHistory(_ journal: URL, root: URL = recordingsDirectory()) throws -> Entry? {
        guard journal.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              journal.lastPathComponent.hasPrefix("capture-"),
              let id = UUID(uuidString: String(journal.lastPathComponent.dropFirst(8))) else { throw CocoaError(.fileReadInvalidFileName) }
        let manager = FileManager.default
        let sizes = try ["system.pcm", "microphone.pcm"].map {
            (try manager.attributesOfItem(atPath: journal.appendingPathComponent($0).path)[.size] as? NSNumber)?.intValue ?? 0
        }
        let archive = root.appendingPathComponent("RecoveredFragments", isDirectory: true)
        try manager.createDirectory(at: archive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archivedJournal = archive.appendingPathComponent(journal.lastPathComponent)
        guard !manager.fileExists(atPath: archivedJournal.path) else { throw CocoaError(.fileWriteFileExists) }
        var result: Entry?
        let bytes = (sizes.max() ?? 0) / 2 * 2
        if bytes > 0 {
            let directory = root.appendingPathComponent("pending", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let metadata = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
            let existing = manager.fileExists(atPath: metadata.path)
                ? try JSONDecoder().decode(Entry.self, from: Data(contentsOf: metadata)) : nil
            if let existing {
                guard existing.kind == "meeting", existing.isArchived else { throw CocoaError(.fileWriteFileExists) }
            }
            let audio = audioURL(id, directory: directory)
            if !manager.fileExists(atPath: audio.path) { try MeetingAudioJournal.recover(directory: journal, to: audio) }
            let file = try FileHandle(forReadingFrom: audio); defer { try? file.close() }
            guard try file.read(upToCount: 44) == MeetingAudioJournal.wavHeader(bytes: bytes),
                  (try manager.attributesOfItem(atPath: audio.path)[.size] as? NSNumber)?.intValue == bytes + 44 else { throw CocoaError(.fileReadCorruptFile) }
            if let existing {
                result = existing
            } else {
                let created = (try manager.attributesOfItem(atPath: journal.path)[.creationDate] as? Date) ?? Date()
                var entry = Entry(id: id, kind: "meeting", created: created)
                entry.archived = true
                try save(entry, directory: directory); result = entry
            }
        }
        try manager.moveItem(at: journal, to: archivedJournal)
        return result
    }
    /// Call once at launch, before starting work. Never silently replay a request
    /// whose response may have been lost when the previous process exited.
    public static func recoverInterruptedProcessing(directory: URL = pendingDirectory()) throws {
        for var entry in try entries(directory: directory) where entry.status == "processing" {
            entry.status = entry.text.isEmpty ? "pending" : "ready"
            entry.error = "Processing was interrupted. Review any existing result before retrying."
            try save(entry, directory: directory)
        }
    }
    public static func discard(_ id: UUID, directory: URL = pendingDirectory()) throws {
        try removeAudio(id, directory: directory)
        let metadata = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
    }
}
