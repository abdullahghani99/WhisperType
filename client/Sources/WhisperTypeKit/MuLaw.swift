import Foundation

/// G.711 mu-law compression for the upload path only.
///
/// The speaker dictates from China to a server in Dubai. Measured on that link:
/// 374 ms round trip and 74.5 KB/s upload, so a median 485 KB dictation spends
/// about 6.5 s on the wire against 2.4 s of actual transcription and polishing,
/// and a long one spends thirty. Roughly three quarters of the wait is moving
/// uncompressed audio, which no amount of server-side work can shorten.
///
/// Mu-law halves it: 8 bits per sample instead of 16, which is what telephony
/// has used for speech for decades and is inaudible to a recogniser.
///
/// Opus would be nearer ten times, and was checked first rather than assumed:
/// macOS can encode it, but only into a CAF container, and the server's decoder
/// reads CAF without supporting Opus inside it ("supported file format but
/// unsupported encoding"). macOS cannot write Ogg natively. Bridging that needs
/// libopus bundled into this app, which is a dependency decision rather than a
/// detail, so it stays a scoped follow-up.
///
/// This touches the UPLOAD only. Capture is untouched, and the full-quality WAV
/// is still what gets written to disk and retained for Inbox recovery, meeting
/// reprocessing and anything else that reads a recording back.
public enum MuLaw {
    private static let bias: Int32 = 0x84
    private static let clip: Int32 = 32635

    /// Compress one 16-bit sample, per ITU-T G.711.
    public static func compress(_ sample: Int16) -> UInt8 {
        var value = Int32(sample)
        let sign: Int32 = value < 0 ? 0x80 : 0
        if value < 0 { value = -value }
        value = min(value, clip) + bias
        // Exponent is the position of the highest set bit above the bias.
        var exponent: Int32 = 7
        var mask: Int32 = 0x4000
        while exponent > 0 && (value & mask) == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (value >> (exponent + 3)) & 0x0F
        return UInt8(~(sign | (exponent << 4) | mantissa) & 0xFF)
    }

    /// Expand one mu-law byte. Present so a round trip can be asserted against
    /// the server's decoder without a network call.
    public static func expand(_ byte: UInt8) -> Int16 {
        let value = Int32(~byte & 0xFF)
        var magnitude = ((value & 0x0F) << 3) + bias
        magnitude <<= ((value & 0x70) >> 4)
        return Int16(clamping: (value & 0x80) != 0 ? bias - magnitude : magnitude - bias)
    }

    /// The sample payload of a 16 kHz mono 16-bit PCM WAV, compressed.
    ///
    /// Returns nil when the input is not that exact shape, so the caller sends
    /// the original bytes instead: a dictation must never be lost to an encoding
    /// problem, and a server that does not understand mu-law must keep working.
    public static func encodeWAV(_ wav: Data) -> Data? {
        guard wav.count > 44, wav.prefix(4) == Data("RIFF".utf8) else { return nil }
        var offset = 12
        var format: UInt16 = 0, channels: UInt16 = 0, bits: UInt16 = 0
        var rate: UInt32 = 0
        var samples: Data?
        while offset + 8 <= wav.count {
            let id = wav.subdata(in: offset..<offset + 4)
            let size = Int(wav.subdata(in: offset + 4..<offset + 8).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian })
            let start = offset + 8
            guard size >= 0, start + size <= wav.count else { return nil }
            if id == Data("fmt ".utf8), size >= 16 {
                let chunk = wav.subdata(in: start..<start + 16)
                chunk.withUnsafeBytes { raw in
                    format = raw.loadUnaligned(fromByteOffset: 0, as: UInt16.self).littleEndian
                    channels = raw.loadUnaligned(fromByteOffset: 2, as: UInt16.self).littleEndian
                    rate = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
                    bits = raw.loadUnaligned(fromByteOffset: 14, as: UInt16.self).littleEndian
                }
            } else if id == Data("data".utf8) {
                samples = wav.subdata(in: start..<start + size)
            }
            offset = start + size + (size % 2)          // chunks are word aligned
        }
        guard format == 1, channels == 1, bits == 16, rate == 16000,
              let pcm = samples, !pcm.isEmpty, pcm.count % 2 == 0 else { return nil }
        var out = Data(capacity: pcm.count / 2)
        pcm.withUnsafeBytes { raw in
            for index in stride(from: 0, to: raw.count, by: 2) {
                out.append(compress(raw.loadUnaligned(fromByteOffset: index, as: Int16.self).littleEndian))
            }
        }
        return out
    }
}
