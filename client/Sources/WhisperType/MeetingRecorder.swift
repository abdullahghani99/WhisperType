import AVFoundation
import ScreenCaptureKit
import Foundation

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
    private(set) var micName = ""
    private let sysQ = DispatchQueue(label: "vf.meeting.sys")
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
        guard !isRecording else { return }
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
        log(micLive ? "recording started (system + mic: \(micName))"
                    : "recording started (system ONLY — no working mic)")
    }

    func stop() async -> Data {
        guard isRecording else { return Data() }
        isRecording = false
        lock.lock(); capturing = false; lock.unlock()
        try? await stream?.stopCapture()
        stream = nil
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        // Streams are stopped now, so no callback can be appending — safe to read
        // without the lock (which isn't allowed from this async context anyway).
        let sys = systemPCM, mic = micPCM
        log("recording stopped (system \(sys.count)B, mic \(mic.count)B)")
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
            micName = dev.name
            log("mic: capturing from \(dev.name) (\(got) frames in probe)")
            return
        }
        micEngine = nil
        micConverter = nil
        log("mic: NO working input device — this meeting will record OTHER participants only")
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
