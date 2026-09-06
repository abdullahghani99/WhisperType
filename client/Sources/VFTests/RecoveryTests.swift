import Foundation
import WhisperTypeKit

final class RecoveryTests: XCTestCase {
    func testSentUnverifiedIsDistinctFromMissingPlacement() {
        var entry = RecordingStore.Entry(kind: "dictation")
        entry.status = "sent_unverified"; entry.text = "Disposable test"
        XCTAssertTrue(entry.sentUnverified)
        XCTAssertTrue(entry.inboxMessage.contains("Typing was sent"))
        entry.status = "ready"; entry.error = "Keys were sent; receipt unavailable"
        XCTAssertTrue(entry.sentUnverified)
        entry.error = "Destination changed"
        XCTAssertFalse(entry.sentUnverified)
    }

    func testCompletedSendLeavesInboxWithoutDeletingRecovery() {
        temporary { directory in
            var entry = try RecordingStore.create(wav: Data([3,4,5]), kind: "dictation", directory: directory)
            entry.text = "The draft is ready."; entry.status = "sent_unverified"; entry.sendCompleted = true
            try RecordingStore.save(entry, directory: directory)
            let saved = try RecordingStore.entries(directory: directory)[0]
            XCTAssertFalse(saved.needsAttention)
            XCTAssertTrue(saved.belongsInSentHistory)
            XCTAssertEqual(saved.status, "sent_unverified")
            XCTAssertEqual(saved.text, entry.text)
            XCTAssertEqual(try Data(contentsOf: RecordingStore.audioURL(entry.id, directory: directory)), Data([3,4,5]))
        }
    }

    func testLegacyCompletedReceiptAndInterruptedSendRouteDifferently() {
        var entry = RecordingStore.Entry(kind: "dictation"); entry.text = "Saved text"
        entry.status = "ready"; entry.error = "Keys were sent; receipt unavailable"
        XCTAssertTrue(entry.belongsInSentHistory); XCTAssertFalse(entry.needsAttention)
        entry.status = "sent_unverified"; entry.error = "Client restarted before insertion verification finished."
        XCTAssertFalse(entry.belongsInSentHistory); XCTAssertTrue(entry.needsAttention)
        entry.status = "ready"; entry.error = "Destination changed while typing. Some text may have been sent."
        XCTAssertFalse(entry.belongsInSentHistory); XCTAssertTrue(entry.needsAttention)
        entry.status = "inserted"; XCTAssertFalse(entry.needsAttention)
    }

    func testPendingFailedEmptyAndEditedResultsRemainActionable() {
        var entry = RecordingStore.Entry(kind: "dictation")
        XCTAssertTrue(entry.needsAttention)
        entry.status = "processing"; XCTAssertTrue(entry.needsAttention)
        entry.status = "ready"; entry.text = "Saved text"; entry.error = "Destination changed"
        XCTAssertTrue(entry.needsAttention); XCTAssertFalse(entry.belongsInSentHistory)
        entry.status = "sent_unverified"; entry.sendCompleted = true; entry.text = ""
        XCTAssertTrue(entry.needsAttention)
        entry.text = "Edited text"; entry.status = "ready"; entry.sendCompleted = false
        XCTAssertTrue(entry.needsAttention); XCTAssertFalse(entry.belongsInSentHistory)
    }

    func testEmptySuccessfulResponseCannotBePresentedAsReady() {
        var entry = RecordingStore.Entry(kind: "dictation")
        entry.status = "ready"; entry.error = "Result ready. Review it in Inbox to choose placement."
        XCTAssertFalse(entry.hasResult)
        XCTAssertEqual(entry.inboxMessage, "No transcript was returned. Your audio is saved.")
        entry.text = " \n "
        XCTAssertFalse(entry.hasResult)
        entry.variants = ["concise": " ", "detailed": "\n"]
        XCTAssertFalse(entry.hasResult)
        entry.variants["detailed"] = "A preserved draft"
        XCTAssertTrue(entry.hasResult)
        entry.variants = [:]; entry.text = "A preserved transcript"
        XCTAssertTrue(entry.hasResult)
    }

    private func temporary(_ body: (URL) throws -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); try body(url) }
        catch { XCTFail("\(error)") }
    }
    func testRapidRecordingsHaveIndependentAudioAndResults() {
        temporary { directory in
            let a = try RecordingStore.create(wav: Data([1,2]), kind: "dictation", directory: directory)
            let b = try RecordingStore.create(wav: Data([3,4]), kind: "prompt", directory: directory)
            XCTAssertNotEqual(a.id, b.id)
            try RecordingStore.removeAudio(a.id, directory: directory)
            XCTAssertEqual(try Data(contentsOf: RecordingStore.audioURL(b.id, directory: directory)), Data([3,4]))
            XCTAssertEqual(try RecordingStore.entries(directory: directory).count, 2)
        }
    }
    func testInterruptedMetadataDoesNotHideAudio() {
        temporary { directory in
            let id = UUID()
            try Data([1,2]).write(to: RecordingStore.audioURL(id, directory: directory))
            let recovered = try RecordingStore.entries(directory: directory)
            XCTAssertEqual(recovered.first?.id, id)
            XCTAssertFalse(recovered.first?.error.isEmpty ?? true)
        }
    }
    func testSaveFailureIsReported() {
        temporary { directory in
            let file = directory.appendingPathComponent("not-a-directory")
            try Data([1]).write(to: file)
            do { _ = try RecordingStore.create(wav: Data([2]), kind: "dictation", directory: file); XCTFail("must reject storage failure") }
            catch { XCTAssertTrue(true) }
        }
    }
    func testRelaunchRecoversInterruptedWorkWithoutReplayingIt() {
        temporary { directory in
            var pending = try RecordingStore.create(wav: Data([1,2]), kind: "dictation", directory: directory)
            pending.status = "processing"; try RecordingStore.save(pending, directory: directory)
            var ready = try RecordingStore.create(wav: Data([3,4]), kind: "prompt", directory: directory)
            ready.status = "processing"; ready.text = "Saved result"; try RecordingStore.save(ready, directory: directory)
            try RecordingStore.recoverInterruptedProcessing(directory: directory)
            let recovered = try RecordingStore.entries(directory: directory)
            XCTAssertEqual(recovered.first { $0.id == pending.id }?.status, "pending")
            XCTAssertEqual(recovered.first { $0.id == ready.id }?.status, "ready")
            XCTAssertEqual(recovered.first { $0.id == ready.id }?.text, "Saved result")
            XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingStore.audioURL(pending.id, directory: directory).path))
        }
    }
    func testJournalMixClipsAndPadsWithoutLosingTail() {
        temporary { directory in
            let journal = try MeetingAudioJournal(parent: directory)
            journal.append(Data([0xff,0x7f, 1,0]), to: .system)
            journal.append(Data([1,0, 2,0, 3,0]), to: .microphone)
            let wav = try journal.finish()
            XCTAssertEqual(wav.count, 50)
            XCTAssertEqual(Data(wav.suffix(6)), Data([0xff,0x7f,3,0,3,0]))
            XCTAssertTrue(FileManager.default.fileExists(atPath: journal.wavURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.directory.path))
        }
    }
    func testInterruptedJournalCanBeRecoveredFromRawFiles() {
        temporary { directory in
            let capture = directory.appendingPathComponent("capture")
            try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
            try Data([1,0,2,0,0xff]).write(to: capture.appendingPathComponent("system.pcm"))
            try Data([3,0]).write(to: capture.appendingPathComponent("microphone.pcm"))
            let wav = directory.appendingPathComponent("recovered.wav")
            try MeetingAudioJournal.recover(directory: capture, to: wav)
            XCTAssertEqual(Data(try Data(contentsOf: wav).suffix(4)), Data([4,0,2,0]))
            XCTAssertTrue(FileManager.default.fileExists(atPath: capture.path), "recovery must preserve original fragments")
        }
    }
    func testJournalBackpressureReportsFailure() {
        temporary { directory in
            let journal = try MeetingAudioJournal(parent: directory)
            journal.append(Data(count: 2 * 1024 * 1024 + 2), to: .system)
            XCTAssertNotNil(journal.error)
            XCTAssertEqual(journal.count(.system), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: journal.directory.path))
        }
    }
    func testConverterDrainsLargeDiagnostics() {
        do {
            let output = try BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "dd if=/dev/zero bs=65536 count=4 >&2 2>/dev/null; printf complete"], timeout: 5)
            XCTAssertEqual(String(data: output.data, encoding: .utf8), "complete")
            XCTAssertEqual(output.diagnostics.utf8.count, 65536)
        } catch { XCTFail("\(error)") }
    }
    func testConverterRejectsPartialFailureAndTimesOut() {
        do {
            _ = try BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf partial; exit 3"])
            XCTFail("partial output must not be accepted")
        } catch { XCTAssertTrue(true) }
        do {
            _ = try BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.05)
            XCTFail("must time out")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
    }
    func testConverterCancellationEndsTheOwnedProcess() {
        let start = Date()
        do {
            _ = try BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
                                       isCancelled: { Date().timeIntervalSince(start) > 0.1 })
            XCTFail("must cancel")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(Date().timeIntervalSince(start) < 3)
    }
    func testStaleMicPublicationCannotReplaceNewEngine() {
        let life = MicLifecycle(wedgeTimeout: 1)
        _ = life.requestStart()
        let first = life.beginAttempt(at: 0)!
        XCTAssertTrue(life.abandonIfWedged(at: 2))
        let second = life.beginAttempt(at: 3)!
        var engine = "none"
        XCTAssertTrue(life.publishAttempt(second) { engine = "second" })
        XCTAssertFalse(life.publishAttempt(first) { engine = "first" })
        XCTAssertEqual(engine, "second")
        XCTAssertTrue(life.requestStop())
        XCTAssertFalse(life.publishAttempt(second) { engine = "after stop" })
        XCTAssertEqual(engine, "second")
    }
}
