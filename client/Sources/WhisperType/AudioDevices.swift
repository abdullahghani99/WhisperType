import CoreAudio
import Foundation

/// Enumerates Core Audio input devices and resolves a saved device by UID, so
/// WhisperType can pin a microphone the user chose instead of following the
/// system default (which macOS keeps flipping to AirPods / iPhone / virtual
/// devices that hand back silence).
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    static let defaultsKey = "vf_micUID"   // "" == follow system default

    static func inputs() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }

        var devs: [AudioInputDevice] = []
        for id in ids where hasInput(id) {
            if let name = stringProp(id, kAudioObjectPropertyName),
               let uid = stringProp(id, kAudioDevicePropertyDeviceUID) {
                devs.append(AudioInputDevice(id: id, uid: uid, name: name))
            }
        }
        return devs
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputs().first { $0.uid == uid }?.id
    }

    /// The device WhisperType should actually capture from:
    ///  - the user's explicit pin, if set;
    ///  - otherwise, if the system default input is Bluetooth (AirPods / Beats
    ///    hand back SILENCE for capture), prefer the built-in mic;
    ///  - otherwise "" = follow the system default.
    /// This is the fix for the recurring "captured 0 bytes" bug.
    /// Respect the user's explicit mic choice; otherwise follow the system
    /// default. Deliberately simple — do NOT override the user's device (an
    /// earlier "prefer built-in / ignore Bluetooth" heuristic broke a working
    /// Bluetooth-headset setup: Bluetooth mics DO work for capture). If a device
    /// genuinely returns silence, the client surfaces that and the user picks
    /// another in Settings.
    static func resolvedInputUID() -> String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? ""
    }

    static func builtInInputUID() -> String? {
        inputs().first { transportType($0.id) == kAudioDeviceTransportTypeBuiltIn }?.uid
    }

    static func defaultInputID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return nil }
        return dev
    }

    static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        return t
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let bufList = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bufList) == noErr else { return false }
        var channels = 0
        for b in UnsafeMutableAudioBufferListPointer(bufList) { channels += Int(b.mNumberChannels) }
        return channels > 0
    }

    private static func stringProp(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: 0)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let st = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard st == noErr, let cf = cf else { return nil }
        return cf.takeRetainedValue() as String
    }
}
