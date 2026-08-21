import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Fires its action at most once — guards the completion against the race
/// between a normal engine bring-up and the wedge watchdog.
private final class Once {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { body() }
    }
}

/// Captures microphone audio and produces a 16 kHz mono 16-bit PCM WAV.
///
/// SMART SINGLE MIC + SELF-HEALING: a fresh engine per recording, pinned to ONE
/// deterministically chosen mic (`AudioDevices.preferredInput()` — wired >
/// built-in > Bluetooth, never the silent AirPods default macOS keeps flipping
/// to).
///
/// Resilience: all audio-HAL work runs off the main thread on a serial queue. A
/// Bluetooth device mid-transition can make a HAL call (`inputFormat` /
/// `engine.start`) BLOCK indefinitely, which would jam that serial queue and
/// silently kill every future recording (the "worked all day, then cut off"
/// bug). A watchdog detects a bring-up that never goes live within
/// `watchdogTimeout`, abandons the wedged attempt (leaking its stuck thread) and
/// swaps in a FRESH queue so the next recording is clean. A generation counter
/// guarantees a late-unblocking stale attempt can't corrupt current state.
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat!
    private var pcm = Data()

    private let bufLock = NSLock()
    private var _isRecording = false
    private var wantRecording = false
    // Bumped on every start / stop / watchdog reset. A bring-up commits its
    // engine only if its captured generation still matches — so an attempt that
    // was superseded (by a fast release or a wedge reset) can't mutate state when
    // it finally unblocks.
    private var generation = 0
    var isRecording: Bool { bufLock.lock(); defer { bufLock.unlock() }; return _isRecording }

    // Replaceable: a wedged BT call leaks its thread, so we abandon the whole
    // queue and make a fresh one rather than wait on the stuck one forever.
    private var engineQueue = DispatchQueue(label: "app.whispertype.client.audio.0")
    private let watchdogTimeout: TimeInterval = 4.0

    var onLevel: ((Float) -> Void)?
    /// Name of the mic used for the last capture (for the dock to display).
    private(set) var lastWinningMic: String?
    private var lastWinningUID: String = ""

    init() {
        outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                  channels: 1, interleaved: true)
    }

    private func logError(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [audio] \(s)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/whispertype-client.log") {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        }
    }

    // No-ops: a fresh engine per recording re-resolves the mic each time, so a
    // device change is picked up automatically — nothing to reload/warm.
    func configurePreroll() {}
    func reloadDevice() {}

    /// Tear down the currently-committed engine (if any). Called on the engine
    /// queue.
    private func teardownCommitted() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
    }

    /// Begin recording. Non-blocking: engine bring-up happens on the engine queue
    /// and `completion(true/false)` is delivered on the MAIN thread when the mic
    /// is live (true) or unavailable/wedged (false).
    func start(_ completion: @escaping (Bool) -> Void) {
        bufLock.lock()
        if _isRecording { bufLock.unlock(); DispatchQueue.main.async { completion(false) }; return }
        wantRecording = true
        generation += 1
        let gen = generation
        pcm = Data()
        let q = engineQueue
        bufLock.unlock()

        let once = Once()
        func report(_ ok: Bool) { once.run { DispatchQueue.main.async { completion(ok) } } }

        // Wedge watchdog: if this attempt is still current yet never went live,
        // the queue is blocked in the HAL (BT transition). Abandon it + reset.
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogTimeout) { [weak self] in
            guard let self = self else { return }
            self.bufLock.lock()
            let wedged = (gen == self.generation) && !self._isRecording
            if wedged {
                self.generation += 1   // invalidate the stuck attempt's future commit
                self.engineQueue = DispatchQueue(label: "app.whispertype.client.audio.\(self.generation)")
                self.wantRecording = false
            }
            self.bufLock.unlock()
            if wedged {
                self.logError("engine bring-up wedged >\(Int(self.watchdogTimeout))s (likely Bluetooth transition) — reset audio queue; next recording is clean")
                report(false)
            }
        }

        q.async { [weak self] in
            guard let self = self else { return }
            self.teardownCommitted()

            // Walk the ranked candidates and keep the FIRST one that actually
            // opens. A disconnected USB mic can linger in CoreAudio as a ghost
            // that enumerates fine but fails engine.start() with -10868; without
            // this fall-through, every press picked that same dead device and
            // dictation stayed broken until the device was manually re-pinned.
            let candidates = AudioDevices.preferredInputs()
            guard !candidates.isEmpty else {
                self.logError("no physical input device available"); report(false); return
            }
            var opened: (engine: AVAudioEngine, converter: AVAudioConverter, name: String, uid: String)?
            for dev in candidates {
                let e = AVAudioEngine()
                let input = e.inputNode
                if let au = input.audioUnit {
                    var id = dev.id
                    let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, 0, &id,
                                                  UInt32(MemoryLayout<AudioDeviceID>.size))
                    if st != noErr {
                        self.logError("skip \(dev.name): could not pin (err \(st))"); continue
                    }
                }
                let inFormat = input.inputFormat(forBus: 0)   // may BLOCK on a BT transition
                guard inFormat.channelCount > 0, inFormat.sampleRate > 0,
                      let conv = AVAudioConverter(from: inFormat, to: self.outFormat) else {
                    self.logError("skip \(dev.name): invalid format (\(inFormat.sampleRate)Hz/\(inFormat.channelCount)ch)")
                    continue
                }
                input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
                    self?.append(buf, gen: gen)
                }
                do {
                    e.prepare()
                    try e.start()                            // may BLOCK on a BT transition
                    opened = (e, conv, dev.name, dev.uid)
                    break
                } catch {
                    self.logError("skip \(dev.name): engine start failed (\(error))")
                    input.removeTap(onBus: 0)
                    continue
                }
            }
            guard let (e, conv, devName, devUID) = opened else {
                self.logError("no input device would open (tried \(candidates.count): \(candidates.map { $0.name }.joined(separator: ", ")))")
                report(false); return
            }

            // Commit only if this attempt is still current AND the user hasn't
            // released — otherwise a watchdog reset or a fast stop() has moved on.
            self.bufLock.lock()
            let current = (gen == self.generation) && self.wantRecording
            if current {
                self.engine = e; self.converter = conv
                self.lastWinningMic = devName; self.lastWinningUID = devUID; self._isRecording = true
            }
            self.bufLock.unlock()

            if current {
                self.logError("capturing from \(devName)")
                report(true)
            } else {
                e.inputNode.removeTap(onBus: 0); e.stop()   // superseded → discard
                report(false)
            }
        }
    }

    /// Stop and return the captured WAV. Fast: the audio is already in memory;
    /// the (potentially slow) teardown happens on the engine queue.
    func stop() -> Data {
        bufLock.lock()
        wantRecording = false
        generation += 1                 // invalidate any in-flight bring-up
        guard _isRecording else { bufLock.unlock(); return Data() }
        _isRecording = false
        let captured = pcm
        let q = engineQueue
        let uid = lastWinningUID
        let name = lastWinningMic ?? "mic"
        bufLock.unlock()

        q.async { [weak self] in self?.teardownCommitted() }
        if captured.isEmpty { logError("captured 0 bytes (device produced no samples)") }
        return wav(from: captured)
    }

    private func append(_ buffer: AVAudioPCMBuffer, gen: Int) {
        guard let converter = converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, let ch = outBuf.int16ChannelData else { return }
        let count = Int(outBuf.frameLength)
        guard count > 0 else { return }
        let d = Data(bytes: ch[0], count: count * MemoryLayout<Int16>.size)

        bufLock.lock()
        let recording = _isRecording && gen == generation
        if recording { pcm.append(d) }
        bufLock.unlock()

        if recording, let cb = onLevel {
            var sum = 0.0
            for i in 0..<count { let s = Double(ch[0][i]) / 32768.0; sum += s * s }
            let level = Float(min(1.0, (sum / Double(count)).squareRoot() * 3.5))
            DispatchQueue.main.async { cb(level) }
        }
    }

    private func wav(from pcm: Data) -> Data {
        let sampleRate: UInt32 = 16_000, channels: UInt16 = 1, bits: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * (bits / 8)
        let dataLen = UInt32(pcm.count)
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        str("RIFF"); u32(36 + dataLen); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bits)
        str("data"); u32(dataLen); d.append(pcm)
        return d
    }
}
