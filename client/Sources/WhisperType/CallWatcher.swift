import AppKit
import CoreAudio
import Foundation
import WhisperTypeKit

/// Watches for calls starting and ending, so a meeting can be offered rather
/// than remembered.
///
/// The signal is CoreAudio's "is this input device running somewhere", which is
/// app-agnostic: Teams, Zoom, Meet in a browser, FaceTime and phone apps all trip
/// it, with no calendar permission and no scraping. `CallDetector` (unit-tested)
/// turns that plus our own engine state into start/end events.
final class CallWatcher {
    private let detector = CallDetector()
    private var timer: Timer?
    /// Asked at each poll: is OUR audio engine holding the mic right now? Without
    /// this the warm pre-roll engine makes every moment look like a call.
    var isOurEngineRunning: () -> Bool = { false }
    var onCallStarted: () -> Void = {}
    var onCallEnded: () -> Void = {}

    private static let conferencingBundleIDs: Set<String> = [
        "com.microsoft.teams", "com.microsoft.teams2", "us.zoom.xos",
        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager",
        "com.apple.FaceTime", "com.tinyspeck.slackmacgap",
        "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
    ]

    func start() {
        stop()
        // 0.5s: responsive enough to offer early, cheap enough to run all day.
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        let signals = CallSignals(
            micInUseBySomeone: Self.anyInputDeviceInUse(),
            ourEngineRunning: isOurEngineRunning(),
            conferencingAppRunning: Self.conferencingAppIsRunning())
        switch detector.update(signals) {
        case .started: onCallStarted()
        case .ended:   onCallEnded()
        case nil:      break
        }
    }

    private static func conferencingAppIsRunning() -> Bool {
        let running = NSWorkspace.shared.runningApplications
        return running.contains { app in
            guard let id = app.bundleIdentifier else { return false }
            return conferencingBundleIDs.contains(id)
        }
    }

    /// True if ANY input device is currently being captured by some process.
    private static func anyInputDeviceInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return false }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return false }
        for id in ids {
            guard AudioDevices.isPhysicalInput(id) else { continue }
            var a = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            var v: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v) == noErr, v == 1 { return true }
        }
        return false
    }
}
