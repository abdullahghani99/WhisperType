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
    private var wantRecording = false   // intent, guarded by bufLock
    var isRecording: Bool { bufLock.lock(); defer { bufLock.unlock() }; return _isRecording }

    // ALL AVAudioEngine work runs here, never on the main thread. Querying the
    // input format / starting the engine does a synchronous dispatch to the audio
    // HAL that can BLOCK for a long time when the input device (e.g. a Bluetooth
    // mic) is transitioning — which froze the whole app ("not responding"). Off
    // the main thread, a slow device can't freeze the UI.
    private let engineQueue = DispatchQueue(label: "app.whispertype.client.audio")

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
    /// engine if pre-roll is enabled, else does nothing. Engine work is on
    /// engineQueue so it can't block the caller (main thread).
    func configurePreroll() {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            if self.prerollEnabled {
                if self.engine == nil { self.continuous = true; self.startEngine() }
            } else {
                self.continuous = false
                if !self.isRecording { self.teardown() }
            }
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
        // Resolve avoids a silent Bluetooth default (AirPods/Beats) when unpinned.
        let uid = AudioDevices.resolvedInputUID()
        if !uid.isEmpty, let devID = AudioDevices.deviceID(forUID: uid), let au = input.audioUnit {
            var dev = devID
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &dev,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { logError("could not pin input device (err \(st))") }
            else { logError("capturing from device uid=\(uid)") }
        } else {
            logError("following system default input")
        }
    }

    /// Begin recording. Non-blocking: engine bring-up happens on engineQueue and
    /// `completion(true/false)` is called back on the MAIN thread when the mic is
    /// actually live (or failed). `completion(false)` = mic unavailable.
    func start(_ completion: @escaping (Bool) -> Void) {
        bufLock.lock()
        if _isRecording { bufLock.unlock(); DispatchQueue.main.async { completion(false) }; return }
        wantRecording = true
        bufLock.unlock()
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            if self.engine == nil { self.startEngine() }   // may block HERE, but off main
            let ok = self.engine != nil
            self.bufLock.lock()
            let stillWant = self.wantRecording
            if ok && stillWant {
                self.pcm = self.continuous ? self.ring : Data()
                self._isRecording = true
            }
            self.bufLock.unlock()
            // User released before the mic came up → don't strand a running engine.
            if ok && !stillWant && !self.continuous { self.teardown() }
            DispatchQueue.main.async { completion(ok && stillWant) }
        }
    }

    /// Stop and return the captured WAV. Fast + non-blocking: the audio bytes are
    /// already in memory (the tap fills `pcm`), so we return immediately and do
    /// the potentially-slow engine teardown on engineQueue (off main).
    func stop() -> Data {
        bufLock.lock()
        wantRecording = false        // cancel a start() still bringing the engine up
        guard _isRecording else { bufLock.unlock(); return Data() }
        _isRecording = false
        let captured = pcm
        let wasContinuous = continuous
        if continuous { ring = Data() }   // keep engine warm for next pre-roll
        bufLock.unlock()

        if !wasContinuous { engineQueue.async { [weak self] in self?.teardown() } }
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
