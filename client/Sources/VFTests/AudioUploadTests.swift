import Foundation
import WhisperTypeKit

/// What each endpoint actually receives.
///
/// v0.7.0 shipped an upload change on the wrong endpoint: the composer got
/// mu-law it cannot decode, ordinary dictation stayed uncompressed, and 111
/// passing tests saw none of it, because every one tested encoder arithmetic and
/// none tested a request. These assert the bodies.
final class AudioUploadTests: XCTestCase {

    /// Every audio POST sends the WAV as-is. The server's decoder is the only
    /// thing on the other end of all of them.
    func testUploadSendsThePlainWAV() {
        let wav = speech()
        let body = AudioUpload.multipart(wav: wav, boundary: "B")
        let head = String(decoding: body.prefix(200), as: UTF8.self)
        XCTAssertTrue(head.contains("filename=\"audio.wav\""))
        XCTAssertTrue(head.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.count > wav.count, "the WAV itself must be in the body")
        XCTAssertTrue(body.range(of: wav) != nil, "the samples must survive intact")
    }

    /// The regression itself: dictation and the composer must send the same
    /// shape. When they differed, one of them was broken for two releases.
    func testEveryEndpointGetsTheSameBodyShape() {
        let wav = speech()
        let dictation = AudioUpload.multipart(wav: wav, boundary: "B")
        let composer  = AudioUpload.multipart(wav: wav, boundary: "B")
        XCTAssertEqual(dictation, composer)
    }

    /// No encoding field: `/engineer` never learned about one, and a body that
    /// declares an encoding the endpoint ignores is how the composer broke.
    func testUploadDeclaresNoEncodingTheEndpointsDoNotAllShare() {
        let body = String(decoding: AudioUpload.multipart(wav: speech(), boundary: "B"), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"encoding\""))
        XCTAssertFalse(body.contains(".ulaw"))
    }

    /// The boundary has to actually close, or the server sees a truncated part.
    func testBodyIsAWellFormedMultipart() {
        let body = String(decoding: AudioUpload.multipart(wav: speech(samples: 4), boundary: "XYZ"), as: UTF8.self)
        XCTAssertTrue(body.hasPrefix("--XYZ\r\n"))
        XCTAssertTrue(body.hasSuffix("\r\n--XYZ--\r\n"))
    }

    /// A 16 kHz mono 16-bit WAV — what the recorder produces.
    private func speech(samples count: Int = 4000) -> Data {
        var data = Data()
        func put(_ s: String) { data.append(Data(s.utf8)) }
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(count * 2)
        put("RIFF"); put32(36 + payload); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1); put32(16000)
        put32(32000); put16(2); put16(16)
        put("data"); put32(payload)
        for i in 0..<count {
            let s = Int16(truncatingIfNeeded: Int(8000 * sin(Double(i) / 12)))
            withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
