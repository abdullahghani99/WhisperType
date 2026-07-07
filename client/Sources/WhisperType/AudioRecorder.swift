import AVFoundation
import Foundation

/// Captures microphone audio and produces a 16 kHz mono 16-bit PCM WAV, which
/// is what whisper wants. Uses the default system input device.
final class AudioRecorder {
    // A fresh engine is created per recording so it always binds to the CURRENT
    // default input device. Reusing one instance broke after a device switch
    // (e.g. PowerConf ⇄ headset) — it captured zero samples.
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat!
    private var pcm = Data()
    private(set) var isRecording = false

    /// Called (on the main queue) with a 0...1 audio level for the waveform UI.
    var onLevel: ((Float) -> Void)?

    private func logError(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [audio] \(s)\n"
        let p = "/tmp/whispertype-client.log"
        if let h = FileHandle(forWritingAtPath: p) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        }
    }

    init() {
        // 16 kHz, mono, 16-bit signed integer, interleaved — whisper's sweet spot.
        outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )
    }

    func start() {
        guard !isRecording else { return }
        pcm = Data()

        let e = AVAudioEngine()          // fresh engine → current default device
        engine = e
        let input = e.inputNode
        let inFormat = input.inputFormat(forBus: 0)

        // Guard against an invalid/asleep device (0 channels / 0 Hz) — that was
        // the zero-samples failure. Bail cleanly so the app doesn't get stuck.
        guard inFormat.channelCount > 0, inFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            logError("no valid input device (fmt=\(inFormat.sampleRate)Hz/\(inFormat.channelCount)ch)")
            engine = nil
            return
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        do {
            e.prepare()
            try e.start()
            isRecording = true
        } catch {
            logError("engine start failed: \(error)")
            engine = nil
        }
    }

    /// Stops capture and returns the recorded audio as a complete WAV file.
    func stop() -> Data {
        guard isRecording, let e = engine else { engine = nil; isRecording = false; return Data() }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        engine = nil
        isRecording = false
        if pcm.isEmpty { logError("captured 0 bytes (device produced no samples)") }
        return wav(from: pcm)
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let err = err {
            FileHandle.standardError.write("convert error: \(err)\n".data(using: .utf8)!)
            return
        }
        if let ch = out.int16ChannelData {
            let count = Int(out.frameLength)
            pcm.append(Data(bytes: ch[0], count: count * MemoryLayout<Int16>.size))

            // RMS level (0...1) for the waveform UI.
            if count > 0, let cb = onLevel {
                var sum: Double = 0
                for i in 0..<count { let s = Double(ch[0][i]) / 32768.0; sum += s * s }
                let rms = (sum / Double(count)).squareRoot()
                let level = Float(min(1.0, rms * 3.5)) // scale up so speech fills the bar
                DispatchQueue.main.async { cb(level) }
            }
        }
    }

    /// Wrap raw 16-bit mono 16 kHz PCM in a minimal WAV container.
    private func wav(from pcm: Data) -> Data {
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataLen = UInt32(pcm.count)

        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }

        str("RIFF"); u32(36 + dataLen); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        str("data"); u32(dataLen); d.append(pcm)
        return d
    }
}
