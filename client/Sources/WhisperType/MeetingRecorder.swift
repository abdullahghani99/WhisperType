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
    private let sysQ = DispatchQueue(label: "vf.meeting.sys")
    private(set) var isRecording = false

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

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sysQ)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sysQ)  // ignored; SCK wants it
        try await s.startCapture()
        stream = s

        startMic()
        isRecording = true
        log("recording started (system + mic)")
    }

    func stop() async -> Data {
        guard isRecording else { return Data() }
        isRecording = false
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
        var pcm = Data()
        if isFloat {
            let ptr = data.assumingMemoryBound(to: Float32.self)
            pcm.reserveCapacity(frames * 2)
            for i in 0..<frames {
                let v = max(-1.0, min(1.0, ptr[i]))
                var s = Int16(v * 32767.0).littleEndian
                pcm.append(Data(bytes: &s, count: 2))
            }
        } else {
            pcm.append(Data(bytes: data, count: Int(abl.mBuffers.mDataByteSize)))
        }
        lock.lock(); systemPCM.append(pcm); lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped with error: \(error)")
    }

    // MARK: mic
    private func startMic() {
        let e = AVAudioEngine()
        micEngine = e
        let input = e.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.channelCount > 0, inFormat.sampleRate > 0,
              let conv = AVAudioConverter(from: inFormat, to: out16k) else {
            log("mic unavailable; capturing system audio only"); micEngine = nil; return
        }
        micConverter = conv
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            self?.appendMic(buf)
        }
        do { e.prepare(); try e.start() } catch { log("mic engine start failed: \(error)"); micEngine = nil }
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
        lock.lock(); micPCM.append(d); lock.unlock()
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
