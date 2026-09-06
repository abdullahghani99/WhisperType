import AppKit
import SwiftUI
import WhisperTypeKit

/// Native state and view construction, with disposable data and no activation,
/// microphone, keyboard events, server requests or user recordings.
func testSentHistoryRouting() {
    let directory = RecordingStore.pendingDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        var sent = try RecordingStore.create(wav: Data([1,2,3]), kind: "dictation")
        sent.text = "A sent draft"; sent.status = "sent_unverified"; sent.sendCompleted = true
        try RecordingStore.save(sent)
        var legacy = try RecordingStore.create(wav: Data([4,5]), kind: "dictation")
        legacy.text = "An earlier sent draft"; legacy.status = "ready"; legacy.error = "Keys were sent; receipt unavailable"
        try RecordingStore.save(legacy)
        var partial = try RecordingStore.create(wav: Data([6,7]), kind: "dictation")
        partial.text = "A partial send"; partial.status = "sent_unverified"; partial.error = "Client restarted before insertion finished"
        try RecordingStore.save(partial)
        let pending = try RecordingStore.create(wav: Data([8,9]), kind: "dictation")
        var verified = RecordingStore.Entry(kind: "dictation")
        verified.text = "A verified draft"; verified.status = "inserted"; try RecordingStore.save(verified)
        let state = SettingsState(); state.reloadRecovery()
        previewCheck(Set(state.recoveryEntries.map(\.id)) == Set([partial.id, pending.id]), "Inbox and its badge must contain only actionable recordings")
        previewCheck(Set(state.sentEntries.map(\.id)) == Set([sent.id, legacy.id]), "Completed unverified sends must be discoverable in History")
        let retained = try Data(contentsOf: RecordingStore.audioURL(sent.id))
        previewCheck(retained == Data([1,2,3]), "Routing must not delete audio")
        let saved = try RecordingStore.entries().first { $0.id == sent.id }
        previewCheck(saved?.status == "sent_unverified" && saved?.text == sent.text, "Routing must not fabricate verification or change text")
        state.reloadRecovery()
        previewCheck(state.recoveryEntries.count == 2 && state.sentEntries.count == 2, "Reload must not promote sent records back into Inbox")
        for recovery in [true, false] {
            let host = NSHostingView(rootView: HistoryTab(state: state, onlyRecovery: recovery))
            host.frame = NSRect(x:0,y:0,width:900,height:800); host.layoutSubtreeIfNeeded()
            previewCheck(host.fittingSize.width > 0 && host.fittingSize.height > 0, "Both native History/Inbox views must construct")
        }
        print("NATIVE SENT HISTORY PASS: actionable badge, legacy routing, interrupted-send retention, reload stability, original audio/text/status preservation, both native views; no focus or microphone")
    } catch { previewFailure("Sent history fixture: \(error)") }
}
