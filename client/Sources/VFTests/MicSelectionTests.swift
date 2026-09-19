import Foundation
import WhisperTypeKit

/// Which microphones WhisperType will record from.
///
/// On 2026-09-15 CoreAudio wedged the built-in microphone: it kept clocking and
/// delivered pure silence for four minutes. The speaker's iPhone microphone was
/// working throughout, and this filter refused it — so there was no fallback and
/// no dictation at all. The ban on Continuity devices is right as a default,
/// because macOS keeps moving the system default onto them, and wrong as an
/// absolute.
final class MicSelectionTests: XCTestCase {
    private func allowed(_ uid: String, _ name: String, physical: Bool = true,
                         bluetooth: Bool = false, pinned: String = "",
                         allowBluetooth: Bool = true) -> Bool {
        MicSelection.allows(uid: uid, name: name, physical: physical,
                            bluetooth: bluetooth, pinned: pinned,
                                  allowBluetooth: allowBluetooth)
    }

    func testAContinuityMicrophoneIsRefusedWhenNobodyAskedForIt() {
        XCTAssertFalse(allowed("uid-phone", "Alex’s iPhone Microphone"))
        XCTAssertFalse(allowed("uid-pad", "Alex’s iPad Microphone"))
    }

    func testTheSpeakersOwnChoiceIsHonoured() {
        XCTAssertTrue(allowed("uid-phone", "Alex’s iPhone Microphone", pinned: "uid-phone"))
    }

    func testPinningOneDeviceDoesNotAdmitTheOthers() {
        XCTAssertFalse(allowed("uid-other-phone", "Someone’s iPhone Microphone", pinned: "uid-phone"))
    }

    func testVirtualDevicesStayRefused() {
        // Opening these wedges the audio HAL, so the NEXT capture returns zero
        // bytes from everything. That is a worse failure than having no mic.
        XCTAssertFalse(allowed("uid-blackhole", "BlackHole 2ch", physical: false))
        XCTAssertFalse(allowed("uid-teams", "Microsoft Teams Audio", physical: false))
    }

    func testAPinnedVirtualDeviceIsStillHonoured() {
        // Pinning is a deliberate statement, and the speaker may be routing
        // audio through a loopback on purpose.
        XCTAssertTrue(allowed("uid-blackhole", "BlackHole 2ch", physical: false, pinned: "uid-blackhole"))
    }

    func testAnOrdinaryMicrophoneIsUnaffected() {
        XCTAssertTrue(allowed("uid-builtin", "MacBook Pro Microphone"))
        XCTAssertTrue(allowed("uid-wire", "Plantronics Blackwire"))
    }

    func testBluetoothStillObeysItsOwnSetting() {
        XCTAssertFalse(allowed("uid-pods", "AirPods Pro", bluetooth: true, allowBluetooth: false))
        XCTAssertTrue(allowed("uid-pods", "AirPods Pro", bluetooth: true, allowBluetooth: true))
        XCTAssertTrue(allowed("uid-pods", "AirPods Pro", bluetooth: true,
                              pinned: "uid-pods", allowBluetooth: false))
    }
}
