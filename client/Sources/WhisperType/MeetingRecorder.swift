import AVFoundation
import ScreenCaptureKit
import Foundation
import os
import VoiceFlowKit

/// Frames counted for ONE probe. Shared, the counter let a superseded engine's
/// callbacks satisfy its replacement's probe, publishing a dead device as live.
private final class ProbeCounter {
    private var frames = 0
    private var lockPrimitive = os_unfair_lock_s()
    func add(_ n: Int) {
        os_unfair_lock_lock(&lockPrimitive); frames += n; os_unfair_lock_unlock(&lockPrimitive)
    }
    var value: Int {
        os_unfair_lock_lock(&lockPrimitive); defer { os_unfair_lock_unlock(&lockPrimitive) }
        return frames
    }
}

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
    /// os_unfair_lock, not NSLock. appendMic runs on the real-time audio thread
    /// and shares this with the ScreenCaptureKit callback and the lifecycle
    /// paths; NSLock can leave a rendering callback waiting behind lower-priority
    /// work, dropping buffers — which this code would then read as the very stall
    /// it exists to detect.
    private var lockPrimitive = os_unfair_lock_s()
    private var systemPCM = Data()   // 16 kHz mono int16
    private var micPCM = Data()
    /// True only when the mic proved it delivers samples. The caller warns the
    /// user when this is false — silently recording half a meeting is not OK.
    private(set) var micLive = false
    /// Continuous liveness watch on the microphone. The opening probe proves a
    /// device STARTED; this proves it is still carrying audio. Without it a
    /// ten-minute meeting recorded 17.8MB of microphone bytes and none of the
    /// user's voice, because the only check ran in the first second.
    private var micHealth: MicHealth?
    private var micWatchdog: Timer?
    /// Every lifecycle decision lives in MicLifecycle, which is unit-tested
    /// without any audio hardware. This class previously carried eleven
    /// independently-settable flags -- starting, stopping, isRecording,
    /// micStarting, recovering, gaveUpOnMic, micGeneration, micStartToken,
    /// micRecoveries, recoveryStartedAt, capturing -- and every fault it had was
    /// a contradictory combination of them that could only be found by running
    /// the app and reading a log.
    private let life = MicLifecycle(maxRecoveries: 3, wedgeTimeout: 8.0)
    var isRecording: Bool { life.currentPhase == .recording }

    private(set) var micStalled = false
    /// Fired the first time the mic goes quiet, and again when recovery gives up.
    /// Losing a meeting's microphone in silence is the most expensive failure this
    /// app has; the human must hear about it while there is still a meeting left.
    var onMicTrouble: ((String) -> Void)?
    /// Fired when a previously stalled microphone carries audio again.
    var onMicRecovered: (() -> Void)?
    private(set) var micName = ""
    private let sysQ = DispatchQueue(label: "vf.meeting.sys")
    /// Expendable: an AVAudioEngine bring-up can wedge, and this queue is
    /// abandoned rather than waited on when it does.
    private var micQ = DispatchQueue(label: "vf.meeting.mic")
    /// Silence inserted to hold the mic track on the system clock. Excluded from
    /// coverage, or a dead microphone reports 100%.
    private var micPaddedBytes = 0
    /// Only pad a gap this large. A converted buffer waiting on the lock looks
    /// exactly like a gap, and padding jitter would push the mic track PAST the
    /// system track, delaying every later word.
    private static let minPadBytes = 16_000
    /// "Giving up" must be said once, not on every three-second tick.
    private var announcedGiveUp = false
    /// The device the current engine is bound to, so a stall demotes the right one.
    private var lastMicUID = ""
    /// The health object of the candidate being probed; becomes `micHealth` only
    /// if that candidate is accepted.
    private var pendingHealth: MicHealth?

    private func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [meeting] \(s)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/voiceflow-client.log") {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        }
    }

    /// Returns false when a meeting is already running or still shutting down.
    /// The caller used to light the red indicator regardless, showing "recording"
    /// while nothing was being captured.
    @discardableResult
    func start() async throws -> Bool {
        guard case .start = life.requestStart() else { return false }
        // A throw below must leave NOTHING running. Returning the state machine to
        // idle was not enough: startMic happens before the ScreenCaptureKit setup,
        // so a throw there left a live engine and tap behind while the app
        // reported idle — the macOS mic indicator stayed on, and the next start
        // built a competing engine over the orphan.
        var began = false
        defer {
            if !began {
                tearDownMic()
                if let s = stream { Task { try? await s.stopCapture() } }
                stream = nil
                life.abandonStart()
            }
        }
        systemPCM = Data(); systemPCM.reserveCapacity(3_840_000)
        micPCM = Data(); micPCM.reserveCapacity(3_840_000)
        // Per MEETING, not per launch. Left cumulative, three recoveries in one
        // meeting meant every later meeting gave up without trying at all.
        micStalled = false
        micPaddedBytes = 0
        announcedGiveUp = false

        // --- system audio via ScreenCaptureKit ---
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "voiceflow", code: 10,
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
        os_unfair_lock_lock(&lockPrimitive)
        // ~2 minutes each (16kHz mono int16). Enough to absorb the early growth
        // that would otherwise reallocate while an audio callback holds the lock,
        // without reserving 76MB up front on a machine that has memory pressure.
        // Longer meetings grow amortised, as they always did.
        systemPCM = Data(); systemPCM.reserveCapacity(3_840_000)
        micPCM = Data(); micPCM.reserveCapacity(3_840_000)
        os_unfair_lock_unlock(&lockPrimitive)
        life.markRecording()
        began = true
        startMicWatchdog()
        if Self.stallSimulationEnabled() {
            log("mic: *** VF_SIMULATE_MIC_STALL IS ACTIVE — the microphone will be reported dead ***")
            DispatchQueue.main.async { [weak self] in
                self?.onMicTrouble?("SIMULATED microphone failure is active (VF_SIMULATE_MIC_STALL).")
            }
        }
        log(micLive ? "recording started (system + mic: \(micName))"
                    : "recording started (system ONLY — no working mic)")
        return true
    }

    func stop() async -> Data {
        // requestStop invalidates taps AND in-flight publications, so a recovery
        // wedged in AVAudioEngine.start() cannot hand us an engine afterwards.
        guard life.requestStop() else { return Data() }
        defer { life.finishStop() }
        micWatchdog?.invalidate(); micWatchdog = nil
        try? await stream?.stopCapture()
        stream = nil
        // Do NOT wait for an in-flight recovery. AVAudioEngine.start() can wedge
        // on a Bluetooth transition -- AudioRecorder abandons a whole queue over
        // exactly this -- and micQ.sync would then never return, stranding the
        // only copy of the meeting in memory. Bumping the generation makes any
        // queued or running recovery a no-op instead of blocking on it.
        // Bumping the generation only silences taps. A recovery blocked inside
        // AVAudioEngine.start() would still PUBLISH its engine after stop, leaving
        // a mic running past the end of the meeting and interfering with the next
        // one. Moving the start token invalidates that publication too.
        tearDownMic()
        // Streams are stopped now, so no callback can be appending — safe to read
        // without the lock (which isn't allowed from this async context anyway).
        let sys = systemPCM, mic = micPCM
        // Report COVERAGE and SIGNAL, not just byte counts. "mic 17833984B" read
        // as success for a meeting that captured none of the user's voice; bytes
        // were never the question.
        let secs = Double(sys.count) / 32_000.0                 // 16kHz mono int16
        let micSecs = Double(mic.count) / 32_000.0
        // Coverage must measure DELIVERED audio, not the silence we padded in to
        // hold alignment -- otherwise a dead microphone reports 100%.
        let coverage = MicLifecycle.coveragePercent(systemBytes: sys.count,
                                                    micBytes: mic.count,
                                                    paddedBytes: micPaddedBytes)
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
        if life.isCapturing {
            os_unfair_lock_lock(&lockPrimitive); systemPCM.append(pcm); os_unfair_lock_unlock(&lockPrimitive)
        }
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
    /// Stop and release the mic engine SAFELY.
    ///
    /// Order matters and is not obvious: stop the engine first, then remove the
    /// tap, holding the engine alive across both. Releasing an AVAudioEngine
    /// while its IO-unit property listener is live crashed this app with
    /// EXC_BAD_ACCESS before, and that listener fires on exactly the device
    /// changes this recovery path exists to handle. Bumping the generation first
    /// makes any in-flight callback a no-op before it can touch replaced state.
    private func tearDownMic() {
        life.invalidateTap()
        guard let e = micEngine else { micConverter = nil; return }
        micEngine = nil
        e.stop()
        e.inputNode.removeTap(onBus: 0)
        micConverter = nil
    }

    /// `reservedToken` is passed when recovery already reserved the attempt slot;
    /// the caller owns ending it. Otherwise this claims the slot itself.
    private func startMic(reservedToken: Int? = nil) {
        let myToken: Int
        let ownsSlot: Bool
        if let t = reservedToken {
            myToken = t; ownsSlot = false          // recovery reserved it; it ends it
        } else {
            guard let t = life.beginAttempt(at: Date().timeIntervalSince1970) else {
                log("mic: start already in progress, ignoring"); return
            }
            myToken = t; ownsSlot = true
        }
        // ONE function-level defer. Placed inside the else branch it fired at the
        // end of that branch, releasing the slot it had just claimed.
        defer { if ownsSlot { life.endAttempt(myToken) } }
        micLive = false
        for dev in AudioDevices.preferredInputs() {
            // Check FIRST, every iteration. An abandoned attempt used to run on
            // and overwrite micConverter, pendingHealth and the probe counter, and
            // bump micGeneration — invalidating the replacement's own tap.
            guard life.isCurrentAttempt(myToken) else {
                log("mic: abandoning superseded probe"); return
            }
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
            let probe = ProbeCounter()            // one per candidate, not shared
            let gen = life.newTapGeneration()
            let health = MicHealth(startedAt: Date().timeIntervalSince1970)
            // Read the fault-injection flag ONCE, here, not on the audio thread.
            let fakeStall = Self.stallSimulationEnabled()
            input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
                guard let self = self else { return }
                probe.add(Int(buf.frameLength))
                self.appendMic(buf, gen: gen, conv: conv, health: health, fakeStall: fakeStall)
            }
            pendingHealth = health
            do { e.prepare(); try e.start() }
            catch {
                log("mic: skip \(dev.name) (engine start failed: \(error))")
                e.stop(); input.removeTap(onBus: 0); continue
            }

            // Opening proves nothing, and neither does a single burst: the
            // built-in mic on this machine delivers ~0.4s of frames and then
            // stalls forever. Require delivery to still be GROWING in a second
            // window, so a device that dies after its first buffer is rejected.
            Thread.sleep(forTimeInterval: 0.35)
            let firstWindow = probe.value
            Thread.sleep(forTimeInterval: 0.35)
            let got = probe.value
            if got == 0 || got <= firstWindow {
                log("mic: skip \(dev.name) (\(got == 0 ? "delivered NO samples" : "stalled after \(got) frames"))")
                AudioDevices.markSilent(uid: dev.uid)
                e.stop(); input.removeTap(onBus: 0); micConverter = nil
                continue
            }

            // A superseded attempt must not publish its engine over a newer one.
            if !life.isCurrentAttempt(myToken) {
                log("mic: discarding \(dev.name) — this attempt was superseded")
                e.stop(); input.removeTap(onBus: 0)
                return
            }
            AudioDevices.markWorking(uid: dev.uid)
            micEngine = e
            micLive = true
            micStalled = false
            micName = dev.name
            lastMicUID = dev.uid
            micHealth = pendingHealth
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
            let now = Date().timeIntervalSince1970

            // KEEP THE TRACKS ON ONE CLOCK, on a timer rather than on buffer
            // arrival: a microphone that stops delivering entirely never triggers
            // catch-up, and mix() aligns by index, so every later word would slide
            // earlier and land over the wrong system audio.
            os_unfair_lock_lock(&self.lockPrimitive)
            if self.life.isCapturing {
                let pad = MicLifecycle.padBytes(systemCount: self.systemPCM.count,
                                                micCount: self.micPCM.count,
                                                minPad: Self.minPadBytes)
                if pad > 0 { self.micPCM.append(Data(count: pad)); self.micPaddedBytes += pad }
            }
            os_unfair_lock_unlock(&self.lockPrimitive)

            // A recovery stuck inside AVAudioEngine.start() must not block every
            // later attempt. Abandon the queue and move on.
            if self.life.abandonIfWedged(at: now) {
                self.micQ = DispatchQueue(label: "vf.meeting.mic")   // fresh; the old is abandoned
                self.log("mic: bring-up wedged >8s — abandoned that attempt, will try again")
            }

            guard let h = self.micHealth else { return }
            guard case .stalled(let quiet) = h.verdict(at: Date().timeIntervalSince1970) else {
                // Healthy again. Clear the warning rather than leaving a stale one
                // on screen for the rest of the meeting.
                if self.micStalled {
                    self.micStalled = false
                    self.log("mic: \(self.micName.isEmpty ? "the microphone" : self.micName) is carrying audio again")
                    DispatchQueue.main.async { self.onMicRecovered?() }
                }
                return
            }
            let firstNotice = !self.micStalled
            self.micStalled = true
            let everWorked = h.everCarriedAudio
            if firstNotice {
                let what = everWorked
                    ? "Your microphone stopped being picked up"
                    : "Your microphone is not being picked up"
                DispatchQueue.main.async { self.onMicTrouble?("\(what) — trying another input…") }
            }
            let who = self.micName.isEmpty ? "no input device" : self.micName
            self.log("mic: \(who) has carried NO audio for \(Int(quiet))s " +
                     "(\(everWorked ? "it was working earlier" : "it never started"))")
            var reservedToken = 0
            let decision = self.life.requestRecovery(at: now)
            switch decision {
            case .alreadyRecovering, .notRecording:
                return                       // padding above still ran
            case .exhausted:
                if !self.announcedGiveUp {
                    self.announcedGiveUp = true
                    self.log("mic: giving up after \(self.life.maxRecoveries) attempts — recording other participants only")
                    DispatchQueue.main.async {
                        self.onMicTrouble?("Still no microphone — this meeting is recording other participants ONLY.")
                    }
                }
                return                       // stop retrying; KEEP padding
            case .recover(let attempt, let of, let token):
                AudioDevices.markSilent(uid: self.lastMicUID)
                self.log("mic: switching device (attempt \(attempt)/\(of))")
                reservedToken = token
            }
            // startMic sleeps while probing, so never run it on the timer thread.
            let token = reservedToken
            self.micQ.async { [weak self] in
                guard let self = self else { return }
                // The slot was reserved when recovery was GRANTED, not here: the
                // gap between the two let later ticks spend the whole retry budget
                // while this closure was still queued.
                defer { self.life.endAttempt(token) }
                guard self.isRecording else { return }
                self.tearDownMic()
                self.startMic(reservedToken: token)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        micWatchdog = t
    }

    /// Fault injection for the recovery path, via the ENVIRONMENT.
    ///
    /// A dead microphone cannot be produced on demand — dropping input gain to
    /// zero still yields a noise floor on both USB and Bluetooth here — so the
    /// path that lost a real meeting has to be exercisable. A persistent
    /// UserDefaults key was the wrong way: left set, it would report every
    /// healthy buffer as silent, on every launch, for every device. An
    /// environment variable cannot outlive the process that was launched with it,
    /// and the normal login launch never sets it.
    ///
    ///     VF_SIMULATE_MIC_STALL=1 /Applications/VoiceFlow.app/Contents/MacOS/VoiceFlow
    /// An environment variable CAN be inherited by every relaunch if a parent
    /// shell or launch service holds it, so it is not self-limiting the way the
    /// comment above once claimed. It therefore announces itself: a build running
    /// with simulation on says so out loud, every meeting, rather than quietly
    /// reporting a healthy microphone as dead.
    private static func stallSimulationEnabled() -> Bool {
        ProcessInfo.processInfo.environment["VF_SIMULATE_MIC_STALL"] == "1"
    }

    /// Runs on the real-time audio thread. Everything it needs is passed in, so
    /// it never resolves shared mutable state mid-render.
    private func appendMic(_ buffer: AVAudioPCMBuffer,
                           gen: Int,
                           conv: AVAudioConverter,
                           health: MicHealth,
                           fakeStall: Bool) {
        // A callback from a superseded engine must not touch anything.
        guard life.isCurrentTap(gen) else { return }

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
        // getting through — the distinction the whole failure turned on.
        var signal = false
        for i in 0..<n where ch[0][i] != 0 { signal = true; break }
        health.observe(at: Date().timeIntervalSince1970, hasSignal: signal && !fakeStall)
        let d = Data(bytes: ch[0], count: n * 2)
        os_unfair_lock_lock(&lockPrimitive)
        if life.isCapturing && life.isCurrentTap(gen) {
            // KEEP THE TWO TRACKS ON ONE CLOCK. mix() aligns by array index, so a
            // gap in microphone delivery -- the seconds with no mic at all, or a
            // recovery spent probing devices -- would slide every later word
            // earlier and lay it over the wrong system audio. System capture runs
            // continuously, so it is the clock: pad the mic with silence up to it
            // before appending. Cheap, and it self-heals every gap.
            let gap = systemPCM.count - micPCM.count
            if gap >= Self.minPadBytes {
                micPCM.append(Data(count: gap))
                micPaddedBytes += gap          // excluded from coverage, like the timer's
            }
            micPCM.append(d)
        }
        os_unfair_lock_unlock(&lockPrimitive)
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
