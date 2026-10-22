import Foundation
import WhisperTypeKit
final class DestinationRecoveryTests: XCTestCase {
    func testNormalTargetHasNoDelay() {
        var g = DestinationRecovery()
        XCTAssertEqual(g.observe(matches: true, applicationChangedOnly: false, cancelled: false), .ready)
    }
    func testReturnRequiresTwoStableMatches() {
        var g = DestinationRecovery()
        for match in [false,true,false,true] { XCTAssertEqual(g.observe(matches: match, applicationChangedOnly: true, cancelled: false), .wait) }
        XCTAssertEqual(g.observe(matches: true, applicationChangedOnly: false, cancelled: false), .ready)
    }
    func testDifferentAppExpiresWithoutRetargeting() {
        var g = DestinationRecovery()
        for _ in 0..<8 { XCTAssertEqual(g.observe(matches: false, applicationChangedOnly: true, cancelled: false), .wait) }
        XCTAssertEqual(g.observe(matches: false, applicationChangedOnly: true, cancelled: false), .stop)
    }
    func testFieldPermissionChangeAndNewCaptureStop() {
        var g = DestinationRecovery()
        XCTAssertEqual(g.observe(matches: false, applicationChangedOnly: true, cancelled: false), .wait)
        XCTAssertEqual(g.observe(matches: false, applicationChangedOnly: false, cancelled: false), .stop)
        var h = DestinationRecovery()
        XCTAssertEqual(h.observe(matches: true, applicationChangedOnly: false, cancelled: true), .stop)
    }
    func testExplicitSavedPlacementExcludesDuplicateAndAmbiguousSends() {
        var e = RecordingStore.Entry(kind: "dictation")
        e.text = "Saved result"; e.status = "ready"; XCTAssertFalse(e.canInsertSavedHere)
        e.placementDeferred = true; XCTAssertTrue(e.canInsertSavedHere)
        e.sendCompleted = true; XCTAssertFalse(e.canInsertSavedHere)
        e.sendCompleted = false
        for status in ["sent_unverified","inserted","processing"] { e.status = status; XCTAssertFalse(e.canInsertSavedHere) }
        e.status = "ready"; e.archived = true; XCTAssertFalse(e.canInsertSavedHere)
        e.archived = false; e.kind = "prompt"; XCTAssertFalse(e.canInsertSavedHere)
        e.kind = "dictation"; e.text = ""; XCTAssertFalse(e.canInsertSavedHere)
    }
    func testLegacyRecoveryAndAttemptMarker() {
        var e = RecordingStore.Entry(kind: "dictation")
        e.text = "Saved result"; e.status = "ready"
        e.error = "Destination changed. Result retained; review placement."; XCTAssertTrue(e.canInsertSavedHere)
        e.placementDeferred = false; XCTAssertFalse(e.canInsertSavedHere)
        e.placementDeferred = nil; e.error = "Destination changed while typing. Some text may have been sent."
        XCTAssertFalse(e.canInsertSavedHere)
    }
}
