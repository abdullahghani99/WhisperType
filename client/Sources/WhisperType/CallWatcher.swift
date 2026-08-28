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
    /// What we saw capturing when the call began (e.g. "Microsoft Teams").
    private(set) var lastCallSource: String = ""
    /// The calling app icon, as PNG, for the dock to show.
    private(set) var lastCallIconPNG: Data?
    /// Asked at each poll: is OUR audio engine holding the mic right now? Without
    /// this the warm pre-roll engine makes every moment look like a call.
    var isOurEngineRunning: () -> Bool = { false }
    var onCallStarted: () -> Void = {}
    var onCallEnded: () -> Void = {}

    /// Real conferencing apps only. Browsers are deliberately absent: Chrome and
    /// Safari are running essentially always, so counting them made every moment
    /// of the day look like a meeting. The cost is that a browser-only Google
    /// Meet is not detected by app name — it is still caught when it holds the
    /// microphone while our own engine is idle.
    private static let conferencingBundleIDs: Set<String> = [
        "com.microsoft.teams", "com.microsoft.teams2", "com.microsoft.teams.classic",
        "us.zoom.xos", "com.cisco.webexmeetingsapp", "com.webex.meetingmanager",
        "com.apple.FaceTime", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "com.google.meet", "com.skype.skype", "com.ringcentral.glip",
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
        // Ask macOS directly WHICH processes are capturing, rather than inferring
        // it. Two heuristics were tried and both mis-fired on a real machine: the
        // microphone signal is polluted by our own warm engine, and "conferencing
        // app running + audio playing" matched an ordinary day with Teams open.
        // The per-process list is exact — it names the capturing process.
        let others = Self.otherProcessesCapturing()
        let signals = CallSignals(
            micInUseBySomeone: !others.isEmpty,
            ourEngineRunning: false,          // we are excluded by name below
            conferencingAppRunning: false,
            audioPlayingSomewhere: false)
        switch detector.update(signals) {
        case .started:
            lastCallSource = others.first?.name ?? ""
            lastCallIconPNG = others.first?.iconPNG
            onCallStarted()
        case .ended:
            onCallEnded()
        case nil:
            break
        }
    }

    /// Which processes OTHER than WhisperType are capturing audio right now.
    /// Available since macOS 14.2; if the property is missing we simply never
    /// report a call rather than falling back to a guess that cries wolf.
    struct Capturer { let name: String; let iconPNG: Data? }

    private static func otherProcessesCapturing() -> [Capturer] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &addr) else { return [] }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &objs) == noErr else { return [] }

        let mine = ProcessInfo.processInfo.processIdentifier
        var found: [Capturer] = []
        for o in objs {
            guard readU32(o, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            guard let raw = readU32(o, kAudioProcessPropertyPID) else { continue }
            let pid = Int32(bitPattern: raw)
            guard pid != mine, pid > 0 else { continue }
            // Only a real user-facing APPLICATION can be a call. Background
            // daemons hold the microphone permanently — Apple's corespeechd
            // (Siri) is always capturing — and counting them meant the dock
            // offered to record a "pid 3990 call" all day long. Daemons have no
            // NSRunningApplication and no bundle identifier, so this excludes
            // them precisely rather than by blocklist.
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier != nil,
                  app.activationPolicy == .regular,
                  let name = app.localizedName, !name.isEmpty else { continue }
            var png: Data?
            if let icon = app.icon, let tiff = icon.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                png = rep.representation(using: .png, properties: [:])
            }
            found.append(Capturer(name: name, iconPNG: png))
        }
        return found
    }

    private static func readU32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var a = AudioObjectPropertyAddress(mSelector: sel,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr, sz == 4 else { return nil }
        var v: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v) == noErr else { return nil }
        return v
    }

    private static func conferencingAppIsRunning() -> Bool {
        let running = NSWorkspace.shared.runningApplications
        return running.contains { app in
            guard let id = app.bundleIdentifier else { return false }
            return conferencingBundleIDs.contains(id)
        }
    }

    /// True if ANY output device is currently playing. This is the half of the
    /// signal WhisperType does not pollute — it captures but never plays — so
    /// unlike the microphone it stays meaningful while our engine is warm.
    private static func anyOutputDeviceInUse() -> Bool {
        deviceIDs().contains { id in
            guard hasOutput(id) else { return false }
            var a = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            var v: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v) == noErr && v == 1
        }
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput, mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let bl = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bl) == noErr else { return false }
        var ch = 0
        for b in UnsafeMutableAudioBufferListPointer(bl) { ch += Int(b.mNumberChannels) }
        return ch > 0
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
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
