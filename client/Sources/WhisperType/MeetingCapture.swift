import AVFoundation
import Foundation

/// Converts an arbitrary audio/video recording (m4a, mp3, mp4, mov…) into the
/// 16 kHz mono 16-bit PCM WAV the server's ASR expects. Used by meeting mode's
/// "Summarize a recording…".
///
/// Prefers ffmpeg when present (on this Mac) because AVAssetReader fails partway
/// through oddly-muxed files — notably Teams .mp4 recordings, where it aborted
/// after ~7 min with "reader status 3". ffmpeg pushes through such files and
/// recovers far more audio. Falls back to the in-process AVFoundation path if
/// ffmpeg isn't installed.
enum MeetingCapture {
    enum ConvertError: Error { case noAudioTrack, readFailed(String) }

    private static let ffmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]

    static func convertToWav16k(_ url: URL) throws -> Data {
        if let ff = ffmpegPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            if let wav = try? convertViaFfmpeg(url, ffmpeg: ff), wav.count > 44 {
                return wav
            }
            // fall through to AVFoundation if ffmpeg produced nothing usable
        }
        return try convertViaAVFoundation(url)
    }

    /// Resilient decode via ffmpeg → 16 kHz mono s16le WAV on stdout.
    private static func convertViaFfmpeg(_ url: URL, ffmpeg: String) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-nostdin", "-v", "error",
                       "-err_detect", "ignore_err", "-fflags", "+discardcorrupt",
                       "-i", url.path, "-ac", "1", "-ar", "16000",
                       "-c:a", "pcm_s16le", "-f", "wav", "pipe:1"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        // Read the pipe on a background queue so a large output can't deadlock.
        var data = Data()
        let g = DispatchGroup(); g.enter()
        let h = out.fileHandleForReading
        DispatchQueue.global().async { data = h.readDataToEndOfFile(); g.leave() }
        try p.run(); p.waitUntilExit(); g.wait()
        return data
    }

    private static func convertViaAVFoundation(_ url: URL) throws -> Data {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw ConvertError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ConvertError.readFailed("cannot add output") }
        reader.add(output)
        guard reader.startReading() else {
            throw ConvertError.readFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        var pcm = Data()
        while let sample = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sample) {
                let len = CMBlockBufferGetDataLength(block)
                var bytes = [UInt8](repeating: 0, count: len)
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: &bytes)
                pcm.append(contentsOf: bytes)
            }
            CMSampleBufferInvalidate(sample)
        }
        guard reader.status == .completed else {
            throw ConvertError.readFailed("reader status \(reader.status.rawValue): \(reader.error?.localizedDescription ?? "")")
        }
        return wav16kMono(pcm)
    }

    /// Wrap 16 kHz mono int16 PCM in a WAV container.
    private static func wav16kMono(_ pcm: Data) -> Data {
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
