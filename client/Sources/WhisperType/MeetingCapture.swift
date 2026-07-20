import AVFoundation
import Foundation

/// Converts an arbitrary audio/video recording (m4a, mp3, mp4, wav, mov…) into
/// the 16 kHz mono 16-bit PCM WAV the server's ASR expects — entirely in-process
/// via AVFoundation (no ffmpeg). Used by meeting mode's "Summarize a recording…".
enum MeetingCapture {
    enum ConvertError: Error { case noAudioTrack, readFailed(String) }

    static func convertToWav16k(_ url: URL) throws -> Data {
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
