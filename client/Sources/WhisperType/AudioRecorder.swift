import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures microphone audio and produces a 16 kHz mono 16-bit PCM WAV.
///
/// Two modes:
///  - one-shot (default): a fresh engine per recording — robust to device
///    changes, mic only active while dictating.
///  - pre-roll (opt-in, "vf_preroll"): the engine runs continuously and keeps a
///    ~1.5 s rolling buffer, so the first words aren't clipped by a mic's
///    wake-up delay (PowerConf/AirPods DSP). Trade-off: the mic stays warm.
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat!
    private var pcm = Data()
    private var ring = Data()
    private let ringMaxBytes = 16_000 * 2 * 3 / 2   // ~1.5 s @ 16k mono int16
    private var continuous = false
    // Guards pcm/ring/_isRecording — the audio tap runs on a real-time thread
    // while start()/stop() run on main; the pre-roll seed (pcm = ring) races the
    // tap's ring mutations without this. Critical sections are tiny (a Data copy).
    private let bufLock = NSLock()
    private var _isRecording = false
    var isRecording: Bool { bufLock.lock(); defer { bufLock.unlock() }; return _isRecording }

    var onLevel: ((Float) -> Void)?
    var prerollEnabled: Bool { UserDefaults.standard.bool(forKey: "vf_preroll") }

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

    /// Call at launch (and when the toggle changes) — starts the always-warm
    /// engine if pre-roll is enabled, else does nothing.
    func configurePreroll() {
        if prerollEnabled {
            if engine == nil { continuous = true; startEngine() }
        } else {
            continuous = false
            if !isRecording { teardown() }
        }
    }

    private func startEngine() {
        let e = AVAudioEngine()
        engine = e
        let input = e.inputNode
        pinDevice(on: input)
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.channelCount > 0, inFormat.sampleRate > 0,
              let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            logError("no valid input device (fmt=\(inFormat.sampleRate)Hz/\(inFormat.channelCount)ch)")
            engine = nil
            return
        }
        converter = conv
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            self?.append(buf)
        }
        do { e.prepare(); try e.start() }
        catch { logError("engine start failed: \(error)"); engine = nil }
    }

    private func teardown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func pinDevice(on input: AVAudioInputNode) {
        let uid = UserDefaults.standard.string(forKey: AudioDevices.defaultsKey) ?? ""
        if !uid.isEmpty, let devID = AudioDevices.deviceID(forUID: uid), let au = input.audioUnit {
            var dev = devID
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &dev,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { logError("could not pin input device (err \(st))") }
        }
    }

    func start() {
        guard !isRecording else { return }
        if continuous {
            // Engine already running — seed the recording with the pre-roll ring.
            if engine == nil { startEngine() }
            bufLock.lock(); pcm = ring; _isRecording = true; bufLock.unlock()
        } else {
            startEngine()
            guard engine != nil else { return }   // mic failed → don't get stuck
            bufLock.lock(); pcm = Data(); _isRecording = true; bufLock.unlock()
        }
    }

    func stop() -> Data {
        bufLock.lock()
        guard _isRecording else { bufLock.unlock(); return Data() }
        _isRecording = false
        let captured = pcm
        if continuous { ring = Data() }   // keep engine warm for next pre-roll
        bufLock.unlock()

        if !continuous { teardown() }
        if captured.isEmpty { logError("captured 0 bytes (device produced no samples)") }
        return wav(from: captured)
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
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
        let recording = _isRecording
        if recording {
            pcm.append(d)
        } else if continuous {
            ring.append(d)
            if ring.count > ringMaxBytes { ring.removeFirst(ring.count - ringMaxBytes) }
        }
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
