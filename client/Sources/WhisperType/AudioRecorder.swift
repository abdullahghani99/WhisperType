import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import WhisperTypeKit

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
    /// When the committed engine started running. A warm engine that has been up
    /// for a while and still delivered NOTHING has a dead tap -- which is exactly
    /// what an input-device change leaves behind for a few seconds.
    private var engineReadyAt: Date?
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat!
    private var pcm = Data()

    private let bufLock = NSLock()
    /// The tested state machine (WhisperTypeKit). Engine epoch and recording state
    /// are deliberately separate: a tap outlives many recordings, so it must
    /// validate against the ENGINE, not against a per-press counter.
    private let state = CaptureState()
    /// Pre-roll: ~1.5s at 16k mono int16, preallocated so the audio thread never
    /// allocates. Only filled while `vf_preroll` is enabled.
    private let ring = PrerollRing(capacityBytes: 16_000 * 2 * 3 / 2)
    private var wantRecording = false
    // Bumped on every start / stop / watchdog reset. A bring-up commits its
    // engine only if its captured generation still matches — so an attempt that
    // was superseded (by a fast release or a wedge reset) can't mutate state when
    // it finally unblocks.
    /// Per-PRESS attempt counter, used only by the wedge watchdog. Deliberately
    /// NOT what the tap validates against — conflating the two is what broke
    /// capture after the first recording.
    private var attempt = 0
    var isRecording: Bool { state.isRecording }

    /// Is OUR audio engine holding the microphone right now — warm pre-roll
    /// included, not just active dictation?
    ///
    /// Call detection depends on this. `isRecording` is false while the warm
    /// engine idles, so using it made the app believe another process held the
    /// mic every second of the day: it "detected a call" at launch, latched, and
    /// then never fired for the real one.
    var isEngineRunning: Bool {
        bufLock.lock(); defer { bufLock.unlock() }
        return engine != nil
    }

    // Replaceable: a wedged BT call leaks its thread, so we abandon the whole
    // queue and make a fresh one rather than wait on the stuck one forever.
    private var engineQueue = DispatchQueue(label: "app.whispertype.client.audio.0")
    /// How long a bring-up may take before it is presumed wedged.
    ///
    /// This MUST exceed the bring-up's own deliberate waiting, and for a while it
    /// did not. 0.4.3 added retries for a Bluetooth device that is not ready yet —
    /// up to 1.2s for pinning plus 1.2s for the format, 2.4s in total — while this
    /// stayed at the 4s chosen before those retries existed. On AirPods, where
    /// every press is now a cold bring-up, the engine spent its budget waiting for
    /// the headset and the watchdog then killed the attempt as wedged: four times
    /// in seven minutes. Two mechanisms of mine fighting each other.
    ///
    /// 8s leaves ~5.6s for the actual HAL work after the retries, and still
    /// abandons a genuinely stuck AVAudioEngine.start() rather than jamming the
    /// queue forever.
    private let watchdogTimeout: TimeInterval = 8.0

    var onLevel: ((Float) -> Void)?
    /// Name of the mic used for the last capture (for the dock to display).
    private(set) var lastWinningMic: String?
    private var lastWinningUID: String = ""
    /// Consecutive silent captures per device UID. One silent capture is treated
    /// as an engine fault; two in a row on the same device is the device.
    private var silentStrikes: [String: Int] = [:]

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

    /// Keeping the microphone warm removes the device wake-up delay that makes a
    /// short press come back empty — but it also means the mic is live whenever
    /// the app is. That is the user's decision, so it stays behind `vf_preroll`.
    /// Warm the engine only where it is FREE.
    ///
    /// A warm mic removes the wake-up delay that made short presses come back
    /// empty. On a Bluetooth headset it also costs the user their music: holding
    /// the mic open drops the device from A2DP to HFP, and playback becomes mono
    /// 16kHz until we let go. Measured, not assumed. So Bluetooth pays the
    /// wake-up delay and keeps its audio; everything else stays warm.
    var prerollEnabled: Bool {
        guard UserDefaults.standard.bool(forKey: "vf_preroll") else { return false }
        // On Bluetooth you cannot have both: holding the mic drops the headset
        // from A2DP (stereo 48kHz) to HFP (mono 16kHz), and releasing it means
        // the link has to come up on each press. That is the Bluetooth spec, not
        // something code can arbitrate.
        //
        // It cannot be decided automatically either. "Is audio playing?" has no
        // reliable answer: DeviceIsRunningSomewhere reads 1 with nothing audible
        // because avconferenced and Safari hold output streams open permanently.
        // Measured, which is why that check is gone.
        //
        // So it is the human's call, and it defaults to FAST.
        if AudioDevices.currentInputIsBluetooth() {
            return UserDefaults.standard.object(forKey: "vf_bluetoothWarm") as? Bool ?? true
        }
        return true
    }

    // The pre-roll reconciler is GONE. It existed to re-warm the mic when
    // playback stopped on a Bluetooth headset -- but the playback detection it
    // depended on was deleted (DeviceIsRunningSomewhere reports playback with
    // nothing audible), so `prerollEnabled` became near-constant and all the
    // reconciler did was retry a failed warm every 2 seconds, forever, with no
    // backoff. It logged 2052 rebuild attempts in ONE DAY: each tears down an
    // AVAudioEngine and builds another, and on Bluetooth one of those releases
    // raced AVAudioIOUnit's device-change property listener and segfaulted the app
    // twice -- EXC_BAD_ACCESS on the AVAudioIOUnit queue, the same crash class
    // teardownCommitted was written to prevent.
    //
    // The warm engine is still warm: configurePreroll() brings it up at launch and
    // reloadDevice() rebuilds it whenever the input device changes. If it dies in
    // between, the next press builds it cold -- a short delay instead of a crash.

    /// Apply a change to the pre-roll setting: warm the engine, or shut it down.
    func configurePreroll() {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            if self.prerollEnabled {
                if self.engine == nil { _ = self.bringUpEngine() }
            } else if !self.state.isRecording {
                self.teardownCommitted()
            }
        }
    }

    /// The chosen microphone changed — rebuild so the new device takes effect,
    /// instead of silently continuing to record the old (possibly unplugged) one.
    func reloadDevice() {
        engineQueue.async { [weak self] in
            guard let self = self, !self.state.isRecording else { return }
            self.teardownCommitted()
            self.ring.reset()
            if self.prerollEnabled { _ = self.bringUpEngine() }
        }
    }

    /// Tear down the currently-committed engine (if any). Called on the engine
    /// queue.
    /// Tear down the committed engine. Invalidating the epoch FIRST means any
    /// buffer still in flight from its tap is discarded rather than landing in a
    /// new recording.
    private func teardownCommitted() {
        state.invalidateEngine()
        guard let e = engine else { converter = nil; return }
        // ORDER MATTERS. Stop the engine first, then remove the tap, and only
        // then drop the reference. Releasing an AVAudioEngine while its IO unit
        // property listener is still live crashed the app with EXC_BAD_ACCESS in
        // AVAudioIOUnit::IOUnitPropertyListener — that listener fires on device
        // changes (AirPods connecting), so it hit exactly when the user switched
        // headphones. Holding `e` until after stop() keeps it alive across the
        // callback instead of freeing it underneath one.
        e.stop()
        e.inputNode.removeTap(onBus: 0)
        engine = nil
        converter = nil
    }

    /// Begin recording. Non-blocking: engine bring-up happens on the engine queue
    /// and `completion(true/false)` is delivered on the MAIN thread when the mic
    /// is live (true) or unavailable/wedged (false).
    func start(_ completion: @escaping (Bool) -> Void) {
        bufLock.lock()
        if state.isRecording { bufLock.unlock(); DispatchQueue.main.async { completion(false) }; return }
        wantRecording = true
        attempt += 1
        let gen = attempt
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
            let wedged = (gen == self.attempt) && !self.state.isRecording
            if wedged {
                self.attempt += 1   // invalidate the stuck attempt
                self.engineQueue = DispatchQueue(label: "app.whispertype.client.audio.\(self.attempt)")
                self.wantRecording = false
            }
            self.bufLock.unlock()
            if wedged {
                self.logError("engine bring-up wedged >\(Int(self.watchdogTimeout))s (likely Bluetooth transition) — reset audio queue; next recording is clean")
                report(false)
            }
        }

        // WARM PATH: the engine is already running (pre-roll on), so the mic is
        // live and the last ~1.5s is already buffered. Start instantly and seed
        // from it, so a device wake-up delay cannot eat the first words — the
        // reason a short press used to come back as a 44-byte header.
        bufLock.lock()
        let haveEngine = (engine != nil && converter != nil)
        bufLock.unlock()
        if haveEngine {
            bufLock.lock(); let seed = Data(ring.drain()); bufLock.unlock()
            // A warm engine goes stale WITHOUT reporting it: AirPods drop the mic
            // link after a few idle minutes, and a device switch leaves the tap
            // bound to the old hardware. The tap keeps firing either way, so the
            // ring fills with SILENCE rather than going empty. A live mic in a
            // quiet room still carries a noise floor, so an all-zero pre-roll of
            // real length means THIS ENGINE is dead -- not the microphone.
            // Rebuild instead of recording nothing and then blaming the device,
            // which is how a perfectly good pair of AirPods got demoted.
            let age = Date().timeIntervalSince(engineReadyAt ?? .distantPast)
            let deliveredNothing = seed.isEmpty && age > 0.5
            let deliveredSilence = seed.count >= Self.staleSeedBytes && Self.isAllZero(seed)
            if deliveredNothing || deliveredSilence {
                logError("warm engine went stale (\(seed.count)B after \(String(format: "%.1f", age))s) — rebuilding")
            } else if state.beginRecording() {
                pcm = seed
                logError("capturing from \(lastWinningMic ?? "mic") (warm, \(seed.count)B pre-roll)")
                report(true)
                return
            }
        }

        q.async { [weak self] in
            guard let self = self else { return }
            // Ownership: act only on the engine THIS task commits. A superseded
            // task (after a watchdog queue swap) must never tear down or mutate a
            // newer engine — that left isRecording true with no engine behind it.
            guard self.bringUpEngine() != nil else {
                self.bufLock.lock(); self.wantRecording = false; self.bufLock.unlock()
                report(false); return
            }
            self.bufLock.lock()
            let stillWant = self.wantRecording
            self.bufLock.unlock()
            guard stillWant, self.state.beginRecording() else {
                if !self.prerollEnabled { self.teardownCommitted() }   // released early
                report(false); return
            }
            self.bufLock.lock(); self.pcm = Data(self.ring.drain()); self.bufLock.unlock()
            self.logError("capturing from \(self.lastWinningMic ?? "mic") (cold)")
            report(true)
        }
    }

    /// Build and commit an engine on the best microphone that actually opens.
    /// Returns the committed epoch, or nil if no device would start.
    /// MUST run on engineQueue.
    @discardableResult
    private func bringUpEngine() -> Int? {
        teardownCommitted()
        let candidates = AudioDevices.preferredInputs()
        guard !candidates.isEmpty else { logError("no physical input device available"); return nil }
        for dev in candidates {
            let e = AVAudioEngine()
            let input = e.inputNode
            if let au = input.audioUnit {
                // Pinning a Bluetooth device fails with -10851 while the link is
                // still coming up — the same not-ready state that makes it report
                // zero input channels a moment later. Observed on AirPods Pro
                // right after they became the default input. Retry briefly before
                // giving up on the device the human actually chose; skipping
                // straight past it is how a call gets recorded on the wrong
                // microphone, or on none.
                var st: OSStatus = noErr
                for attempt in 0..<6 {                    // up to ~1.2s
                    var id = dev.id
                    st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &id,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
                    if st == noErr {
                        if attempt > 0 { logError("\(dev.name) pinned on attempt \(attempt + 1)") }
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                }
                if st != noErr {
                    logError("skip \(dev.name): could not pin (err \(st)) after 6 attempts")
                    e.stop(); continue
                }
            }
            // A Bluetooth headset reports ZERO input channels while it negotiates
            // the mic link — measured on AirPods Pro: "24000.0Hz/0ch", repeatedly,
            // for a second or so after it becomes the input device. Treating that
            // as an unusable device is what "no audio recording via the AirPods"
            // actually was: the format is not invalid, the device is not ready yet.
            // Wait briefly rather than skipping to a worse microphone. Bounded and
            // synchronous on the engine queue -- the previous attempt at handling
            // this was a background timer that retried every 2s forever and
            // segfaulted the app.
            var inFormat = input.inputFormat(forBus: 0)
            if inFormat.channelCount == 0 || inFormat.sampleRate == 0 {
                for _ in 0..<6 {                       // up to ~1.2s
                    Thread.sleep(forTimeInterval: 0.2)
                    inFormat = input.inputFormat(forBus: 0)
                    if inFormat.channelCount > 0 && inFormat.sampleRate > 0 { break }
                }
                if inFormat.channelCount > 0 {
                    logError("\(dev.name) was not ready; it settled at \(inFormat.sampleRate)Hz/\(inFormat.channelCount)ch")
                }
            }
            guard inFormat.channelCount > 0, inFormat.sampleRate > 0,
                  let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
                logError("skip \(dev.name): invalid format (\(inFormat.sampleRate)Hz/\(inFormat.channelCount)ch)")
                e.stop()          // never abandon an engine un-stopped (see teardown)
                continue
            }
            // Stamp the tap with THIS engine's epoch. It is installed once and
            // outlives many recordings; the state machine decides per buffer
            // whether it feeds the recording, the pre-roll, or nothing at all.
            let epoch = state.commitEngine()
            input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
                self?.append(buf, epoch: epoch)
            }
            do { e.prepare(); try e.start() }
            catch {
                logError("skip \(dev.name): engine start failed (\(error))")
                e.stop()
                input.removeTap(onBus: 0)
                state.invalidateEngine()
                continue
            }
            engine = e; converter = conv
            engineReadyAt = Date()
            lastWinningMic = dev.name; lastWinningUID = dev.uid
            return epoch
        }
        logError("no input device would open (tried \(candidates.count))")
        return nil
    }

    /// Stop and return the captured WAV. Fast: the audio is already in memory;
    /// the (potentially slow) teardown happens on the engine queue.
    func stop() -> Data {
        bufLock.lock()
        wantRecording = false
        attempt += 1                    // invalidate any in-flight bring-up
        guard state.isRecording else { bufLock.unlock(); return Data() }
        state.endRecording()            // engine STAYS committed; tap stays valid
        let captured = pcm
        let q = engineQueue
        let uid = lastWinningUID
        let name = lastWinningMic ?? "mic"
        bufLock.unlock()

        // Release the microphone unless the human asked us to keep it warm.
        // Pre-roll removes the device wake-up delay, but it also means the mic is
        // live whenever the app is — so it stays their choice, not ours.
        ring.reset()
        if prerollEnabled {
            logError("engine kept warm for the next press (pre-roll on)")
        } else {
            q.async { [weak self] in self?.teardownCommitted() }
        }

        // Opening a device proves nothing; only real samples do. Teach the picker
        // what this device actually delivered so a broken mic is demoted instead
        // of being chosen again on every press.
        //
        // Byte count alone is not enough: a broken device can stream ZERO-VALUED
        // buffers, which makes `captured` large while containing no audio at all.
        // A real mic in a silent room still carries a noise floor, so an
        // all-zero buffer means the hardware is dead, not that the room is quiet.
        // Tri-state, unit-tested in WhisperTypeKit: all-zero audio means a dead
        // device at any length, a short press is evidence of NOTHING, and only a
        // long non-zero capture proves the mic works.
        let verdict = CaptureState.classify(byteCount: captured.count,
                                            allZero: Self.isAllZero(captured))
        switch verdict {
        case .silent:
            // ONE silent capture is an ENGINE fault far more often than a device
            // fault. Measured: the Beats delivered 3.3s of zeros through
            // WhisperType's warm engine while an independent AVAudioEngine on the
            // same device, seconds later, read 64000 non-zero frames at peak
            // 0.86. The hardware was fine; the engine had gone quiet mid-press,
            // which no pre-press check can see. Demoting on that single sample
            // banished a working headset for ten minutes and sent dictation to a
            // worse microphone — the exact complaint this keeps producing.
            //
            // So: rebuild first, demote only if the SAME device fails again. A
            // genuinely dead device fails every time and is demoted on the second
            // press; a stale engine is repaired without the human losing a device.
            if !uid.isEmpty {
                let strikes = (silentStrikes[uid] ?? 0) + 1
                silentStrikes[uid] = strikes
                if strikes >= 2 {
                    AudioDevices.markSilent(uid: uid)
                    logError("\(name) produced no usable audio twice (\(captured.count) bytes) — demoting it")
                    silentStrikes[uid] = 0
                } else {
                    logError("\(name) produced no usable audio (\(captured.count) bytes) — rebuilding the engine, not blaming the device")
                }
            } else {
                logError("captured \(captured.count) bytes (device produced no samples)")
            }
            // Either way the engine is suspect and must not stay warm.
            q.async { [weak self] in self?.teardownCommitted() }
        case .working:
            if !uid.isEmpty {
                AudioDevices.markWorking(uid: uid)
                silentStrikes[uid] = 0        // it delivered; the slate is clean
            }
        case .inconclusive:
            logError("\(name): \(captured.count) bytes — too short to judge the mic, leaving its standing unchanged")
        }
        return wav(from: captured)
    }

    private func append(_ buffer: AVAudioPCMBuffer, epoch: Int) {
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

        var recording = false
        switch state.route(epoch: epoch) {
        case .recording:
            bufLock.lock(); pcm.append(d); bufLock.unlock()
            recording = true
        case .preroll:
            // Fixed-capacity ring: no allocation or compaction on the audio thread.
            if prerollEnabled { ring.append([UInt8](d)) }
        case .discard:
            return   // from an engine we have already replaced
        }

        if recording, let cb = onLevel {
            var sum = 0.0
            for i in 0..<count { let s = Double(ch[0][i]) / 32768.0; sum += s * s }
            let level = Float(min(1.0, (sum / Double(count)).squareRoot() * 3.5))
            DispatchQueue.main.async { cb(level) }
        }
    }

    /// True when every sample is exactly zero — the signature of a dead device.
    /// A working mic always carries some noise floor, so this cannot be confused
    /// with a quiet room.
    /// Half a second of pre-roll. Enough that a device genuinely mid-start-up is
    /// not mistaken for a dead one, small enough to catch a stale ring long
    /// before it fills.
    static let staleSeedBytes = 16_000

    static func isAllZero(_ d: Data) -> Bool {
        guard !d.isEmpty else { return true }
        return d.withUnsafeBytes { raw in
            for b in raw where b != 0 { return false }
            return true
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
