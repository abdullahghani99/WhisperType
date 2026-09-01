import AVFoundation
import ScreenCaptureKit
import Foundation
import WhisperTypeKit

/// Live meeting recorder: captures SYSTEM audio (everyone else on the call, via
/// ScreenCaptureKit) + your MIC (AVAudioEngine) simultaneously, mixes them into
/// one 16 kHz mono track, and returns a WAV for the /meeting endpoint.
///
/// Requires Screen Recording permission (System Settings ▸ Privacy & Security ▸
/// Screen Recording) — the first start triggers the prompt. Isolated from the
/// dictation path; a failure here never affects push-to-talk.
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var micEngine: AVAudioEngine?
    private var micConverter: AVAudioConverter?
    private let out16k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                       channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var systemPCM = Data()   // 16 kHz mono int16
    private var micPCM = Data()
    private var probeFrames = 0
    private let probeLock = NSLock()
    /// True only when the mic proved it delivers samples. The caller warns the
    /// user when this is false — silently recording half a meeting is not OK.
    private(set) var micLive = false
    /// Continuous liveness watch on the microphone. The opening probe proves a
    /// device STARTED; this proves it is still carrying audio. Without it a
    /// ten-minute meeting recorded 17.8MB of microphone bytes and none of the
    /// user's voice, because the only check ran in the first second.
    private var micHealth: MicHealth?
    private var micWatchdog: Timer?
    private var micRecoveries = 0
    private let maxMicRecoveries = 3
    /// True once the mic has been silent long enough to matter, so the UI can say
    /// so WHILE the meeting is running instead of after it is lost.
    private(set) var micStalled = false
    /// Fired on the main queue the first time the mic goes quiet, and again when
    /// recovery gives up. Losing a meeting's microphone in silence is the single
    /// most expensive failure this app has; the human has to hear about it while
    /// there is still a meeting left to save.
    var onMicTrouble: ((String) -> Void)?
    private(set) var micName = ""
    private let sysQ = DispatchQueue(label: "vf.meeting.sys")
    private let micQ = DispatchQueue(label: "vf.meeting.mic")
    /// The device the current mic engine is bound to, so a stall demotes the
    /// right one rather than whatever happens to rank first now.
    private var lastMicUID = ""
    /// Set SYNCHRONOUSLY at the top of start(). isRecording is only true after
    /// two awaits, so it could not keep a second start() out of the window in
    /// between: both ran startMic(), and the loser nilled micConverter under the
    /// winner's still-installed tap. The meeting then recorded 0 microphone
    /// bytes while the probe had reported 14400 healthy frames.
    private var starting = false
    /// startMic sleeps while probing, so two of them must never overlap.
    private var micStarting = false
    private(set) var isRecording = false
    /// Both tracks only accumulate once BOTH streams are live, so sample 0 of the
    /// mic and sample 0 of the system audio are the same instant. mix() aligns by
    /// index, so a head start on either side shifts one speaker in time.
    private var capturing = false

    private func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [meeting] \(s)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/whispertype-client.log") {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        }
    }

    func start() async throws {
        lock.lock()
        if isRecording || starting { lock.unlock(); return }
        starting = true
        lock.unlock()
        defer { lock.lock(); starting = false; lock.unlock() }
        systemPCM = Data(); micPCM = Data()

        // --- system audio via ScreenCaptureKit ---
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "whispertype", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "no display for capture"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 16_000
        cfg.channelCount = 1
        cfg.width = 2; cfg.height = 2          // minimal video (SCK needs a size)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        // Bring the MIC up first: its liveness probe takes time, and if system
        // capture were already running that delay would become a permanent
        // offset between the two tracks.
        startMic()

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sysQ)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sysQ)  // ignored; SCK wants it
        try await s.startCapture()
        stream = s

        // Both streams are live now — discard probe/preroll audio and start the
        // clock for both tracks at the same instant.
        lock.lock(); systemPCM = Data(); micPCM = Data(); capturing = true; lock.unlock()
        isRecording = true
        startMicWatchdog()
        log(micLive ? "recording started (system + mic: \(micName))"
                    : "recording started (system ONLY — no working mic)")
    }

    func stop() async -> Data {
        guard isRecording else { return Data() }
        isRecording = false
        lock.lock(); capturing = false; lock.unlock()
        micWatchdog?.invalidate(); micWatchdog = nil
        try? await stream?.stopCapture()
        stream = nil
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        // Streams are stopped now, so no callback can be appending — safe to read
        // without the lock (which isn't allowed from this async context anyway).
        let sys = systemPCM, mic = micPCM
        // Report COVERAGE and SIGNAL, not just byte counts. "mic 17833984B" read
        // as success for a meeting that captured none of the user's voice; bytes
        // were never the question.
        let secs = Double(sys.count) / 32_000.0                 // 16kHz mono int16
        let micSecs = Double(mic.count) / 32_000.0
        let coverage = secs > 0 ? Int(micSecs / secs * 100) : 0
        let carried = micHealth?.everCarriedAudio ?? false
        log("recording stopped (system \(sys.count)B / \(String(format: "%.0f", secs))s, " +
            "mic \(mic.count)B / \(String(format: "%.0f", micSecs))s = \(coverage)% coverage, " +
            "mic carried audio: \(carried ? "YES" : "NO"))")
        if micLive && (coverage < 60 || !carried) {
            log("mic: WARNING — the microphone track is incomplete; the human should be told")
            DispatchQueue.main.async { [weak self] in
                self?.onMicTrouble?(carried
                    ? "Your microphone only covered \(coverage)% of that meeting."
                    : "Your microphone captured NO audio in that meeting.")
            }
        }
        return wav(from: mix(sys, mic))
    }

    // MARK: system audio callback
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
        let frames = CMItemCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return }
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard st == noErr, let data = abl.mBuffers.mData else { return }
        // SCK delivers float32 PCM; convert to int16 (config already made it 16k mono).
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        // Convert the whole buffer in one allocation. The previous version built a
        // fresh 2-byte Data per SAMPLE — ~57 million allocations an hour at 16 kHz,
        // which is pure allocator churn during a long call.
        let pcm: Data
        if isFloat {
            let ptr = data.assumingMemoryBound(to: Float32.self)
            var scratch = [Int16](repeating: 0, count: frames)
            for i in 0..<frames {
                let v = max(-1.0, min(1.0, ptr[i]))
                scratch[i] = Int16(v * 32767.0).littleEndian
            }
            pcm = scratch.withUnsafeBufferPointer { Data(buffer: $0) }
        } else {
            pcm = Data(bytes: data, count: Int(abl.mBuffers.mDataByteSize))
        }
        lock.lock(); if capturing { systemPCM.append(pcm) }; lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped with error: \(error)")
    }

    // MARK: mic
    /// Start the local mic for the meeting mix.
    ///
    /// This deliberately does NOT trust the system default input. A disconnected
    /// USB mic can linger in CoreAudio as the default, open without error, and
    /// deliver pure silence — which is exactly how a meeting was recorded with
    /// the other participant audible and the user's own voice entirely missing.
    /// So: walk the ranked candidates, and PROVE each one delivers samples before
    /// accepting it. A meeting is not latency-sensitive, so a short liveness
    /// probe is cheap insurance against losing half a conversation.
    private func startMic() {
        lock.lock()
        if micStarting { lock.unlock(); log("mic: start already in progress, ignoring"); return }
        micStarting = true
        lock.unlock()
        defer { lock.lock(); micStarting = false; lock.unlock() }
        micLive = false
        for dev in AudioDevices.preferredInputs() {
            let e = AVAudioEngine()
            let input = e.inputNode
            if let au = input.audioUnit {
                var id = dev.id
                let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &id,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
                if st != noErr { log("mic: skip \(dev.name) (could not pin, err \(st))"); continue }
            }
            let inFormat = input.inputFormat(forBus: 0)
            guard inFormat.channelCount > 0, inFormat.sampleRate > 0,
                  let conv = AVAudioConverter(from: inFormat, to: out16k) else {
                log("mic: skip \(dev.name) (invalid format)"); continue
            }
            micConverter = conv
            probeFrames = 0
            input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
                guard let self = self else { return }
                self.probeLock.lock(); self.probeFrames += Int(buf.frameLength); self.probeLock.unlock()
                self.appendMic(buf)
            }
            do { e.prepare(); try e.start() }
            catch {
                log("mic: skip \(dev.name) (engine start failed: \(error))")
                input.removeTap(onBus: 0); continue
            }

            // Opening proves nothing, and neither does a single burst: the
            // built-in mic on this machine delivers ~0.4s of frames and then
            // stalls forever. Require delivery to still be GROWING in a second
            // window, so a device that dies after its first buffer is rejected.
            Thread.sleep(forTimeInterval: 0.35)
            probeLock.lock(); let firstWindow = probeFrames; probeLock.unlock()
            Thread.sleep(forTimeInterval: 0.35)
            probeLock.lock(); let got = probeFrames; probeLock.unlock()
            if got == 0 || got <= firstWindow {
                log("mic: skip \(dev.name) (\(got == 0 ? "delivered NO samples" : "stalled after \(got) frames"))")
                AudioDevices.markSilent(uid: dev.uid)
                input.removeTap(onBus: 0); e.stop(); micConverter = nil
                continue
            }

            AudioDevices.markWorking(uid: dev.uid)
            micEngine = e
            micLive = true
            micStalled = false
            micName = dev.name
            lastMicUID = dev.uid
            if let h = micHealth { h.reset(at: Date().timeIntervalSince1970) }
            else { micHealth = MicHealth(startedAt: Date().timeIntervalSince1970) }
            log("mic: capturing from \(dev.name) (\(got) frames in probe)")
            return
        }
        micEngine = nil
        micConverter = nil
        lastMicUID = ""
        // Arm the clock anyway. Previously micHealth stayed nil when nothing was
        // accepted, so the watchdog returned early and NEVER retried -- a
        // Bluetooth headset that was two seconds from being ready was lost for
        // the whole meeting.
        micHealth = MicHealth(startedAt: Date().timeIntervalSince1970)
        log("mic: NO working input device — this meeting will record OTHER participants only")
    }

    /// Watch the microphone for the WHOLE meeting, not just its first second.
    ///
    /// When a mic stops carrying audio we switch to the next candidate device and
    /// keep recording. The failed one is demoted first, so preferredInputs ranks
    /// it last and we do not land straight back on it. Bounded, because thrashing
    /// between two broken devices for an hour would be its own failure.
    private func startMicWatchdog() {
        micWatchdog?.invalidate()
        // NOT scheduledTimer: start() is async, so this runs off the main thread
        // where there is no run loop to attach to, and the timer never fired at
        // all. Build it unscheduled and add it to the main run loop explicitly.
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            guard let h = self.micHealth else { return }
            guard case .stalled(let quiet) = h.verdict(at: Date().timeIntervalSince1970) else { return }
            let firstNotice = !self.micStalled
            self.micStalled = true
            let everWorked = h.everCarriedAudio
            if firstNotice {
                let what = everWorked
                    ? "Your microphone stopped being picked up"
                    : "Your microphone is not being picked up"
                DispatchQueue.main.async { self.onMicTrouble?("\(what) — trying another input…") }
            }
            self.log("mic: \(self.micName) has carried NO audio for \(Int(quiet))s " +
                     "(\(everWorked ? "it was working earlier" : "it never started"))")
            guard self.micRecoveries < self.maxMicRecoveries else {
                self.log("mic: giving up after \(self.micRecoveries) attempts — recording other participants only")
                DispatchQueue.main.async {
                    self.onMicTrouble?("Still no microphone — this meeting is recording other participants ONLY.")
                }
                self.micWatchdog?.invalidate(); self.micWatchdog = nil
                return
            }
            self.micRecoveries += 1
            AudioDevices.markSilent(uid: self.lastMicUID)
            self.log("mic: switching device (attempt \(self.micRecoveries)/\(self.maxMicRecoveries))")
            // startMic sleeps while probing, so never run it on the timer thread.
            self.micQ.async { [weak self] in
                guard let self = self, self.isRecording else { return }
                self.micEngine?.inputNode.removeTap(onBus: 0)
                self.micEngine?.stop()
                self.micEngine = nil
                self.micConverter = nil
                self.startMic()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        micWatchdog = t
    }

    private func appendMic(_ buffer: AVAudioPCMBuffer) {
        guard let conv = micConverter else { return }
        let ratio = out16k.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: out16k, frameCapacity: cap) else { return }
        var fed = false; var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, let ch = outBuf.int16ChannelData else { return }
        let n = Int(outBuf.frameLength)
        // Does this buffer carry SIGNAL, or is it zero-filled? A live mic in a
        // quiet room still has a noise floor, so all-zero means nothing is
        // coming through -- the distinction the whole failure turned on.
        var signal = false
        for i in 0..<n where ch[0][i] != 0 { signal = true; break }
        // `vf_simulateMicStall` pretends the mic went quiet, so the recovery path
        // can actually be exercised. A dead microphone cannot be produced on
        // demand -- dropping input gain to zero still yields a noise floor on both
        // USB and Bluetooth here -- and this path is the one that lost a real
        // meeting, so it must be testable rather than assumed.
        let faked = UserDefaults.standard.bool(forKey: "vf_simulateMicStall")
        micHealth?.observe(at: Date().timeIntervalSince1970, hasSignal: signal && !faked)
        let d = Data(bytes: ch[0], count: n * 2)
        lock.lock(); if capturing { micPCM.append(d) }; lock.unlock()
    }

    // MARK: mix + wav
    /// Sum two 16 kHz mono int16 streams sample-wise (clip), pad the shorter.
    /// Writes into ONE preallocated buffer — must stay fast for long meetings.
    /// (The previous per-sample allocating loop effectively hung on ~40M-sample
    /// recordings, so a 44-min meeting never reached the upload step.)
    private func mix(_ a: Data, _ b: Data) -> Data {
        let na = a.count / 2, nb = b.count / 2, n = max(na, nb)
        if n == 0 { return Data() }
        var out = [Int16](repeating: 0, count: n)
        out.withUnsafeMutableBufferPointer { o in
            a.withUnsafeBytes { (pa: UnsafeRawBufferPointer) in
                b.withUnsafeBytes { (pb: UnsafeRawBufferPointer) in
                    let sa = pa.bindMemory(to: Int16.self)
                    let sb = pb.bindMemory(to: Int16.self)
                    for i in 0..<n {
                        let va = i < na ? Int32(sa[i]) : 0
                        let vb = i < nb ? Int32(sb[i]) : 0
                        o[i] = Int16(max(-32768, min(32767, va + vb)))
                    }
                }
            }
        }
        return out.withUnsafeBytes { Data($0) }
    }

    private func wav(from pcm: Data) -> Data {
        let sr: UInt32 = 16_000, ch: UInt16 = 1, bits: UInt16 = 16
        let byteRate = sr * UInt32(ch) * UInt32(bits / 8)
        let blockAlign = ch * (bits / 8)
        let dataLen = UInt32(pcm.count)
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        str("RIFF"); u32(36 + dataLen); str("WAVE"); str("fmt "); u32(16); u16(1); u16(ch)
        u32(sr); u32(byteRate); u16(blockAlign); u16(bits); str("data"); u32(dataLen); d.append(pcm)
        return d
    }
}
