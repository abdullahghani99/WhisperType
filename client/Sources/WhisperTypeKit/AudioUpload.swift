import Foundation

/// The multipart body for an audio upload.
///
/// One builder, used by every audio POST, because the call sites drifted once:
/// v0.7.0 put mu-law compression on `/engineer`, which has no `encoding`
/// parameter and decodes the bytes as WAV, while `/whispertype` -- the endpoint
/// that was extended to accept it, and the one carrying every ordinary dictation
/// -- kept sending PCM. The composer broke and the advertised speed-up never
/// shipped. 111 tests passed throughout: all of them asserted the encoder's
/// arithmetic, none asserted what an endpoint receives.
///
/// Uploads are uncompressed, and that is now a measured decision rather than an
/// omission. Compressing to G.711 mu-law was built, shipped and then removed:
///
///   - Benefit, measured against the live server on a 3.9 MB recording, four
///     alternating runs: 17.2-17.5 s uncompressed against 16.3-16.5 s
///     compressed. Halving the bytes bought 1.1 s of 17.4 s. The implied link
///     throughput was about 1.8 MB/s, roughly twenty times the 74.5 KB/s that
///     motivated the work -- so on a median 485 KB dictation the saving is
///     around 0.1 s.
///   - Cost, same recording, same server: the transcript changed by 32%
///     (similarity 0.676). The decoder is deterministic -- two uncompressed runs
///     were character-identical -- so that is compression, not sampling noise.
///     It is not this encoder's rounding either: ffmpeg's own G.711 output
///     scored 0.769 on the same audio. Eight-bit quantisation simply costs
///     Whisper accuracy, and cost it most on non-English speech.
///
/// A tenth of a second is not worth a third of a transcript. If uploads ever do
/// dominate again, measure first, and reach for Opus (about ten times smaller at
/// far better fidelity) rather than mu-law.
public enum AudioUpload {

    /// Build the body for one audio POST.
    public static func multipart(wav: Data, boundary: String) -> Data {
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        add("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        add("\r\n--\(boundary)--\r\n")
        return body
    }
}
