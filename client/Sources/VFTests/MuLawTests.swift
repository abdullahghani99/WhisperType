import Foundation
import WhisperTypeKit

/// The encoder has to agree with the server's decoder exactly. It never fails
/// loudly if it does not -- audio would just arrive distorted and transcribe
/// slightly worse, which is the kind of fault that survives for weeks.
final class MuLawTests: XCTestCase {

    /// ITU-T G.711 anchor points, the same six the server asserts at import.
    func testExpansionMatchesTheStandard() {
        let anchors: [UInt8: Int16] = [0x00: -32124, 0x80: 32124, 0x7F: 0,
                                       0xFF: 0, 0xFE: 8, 0x7E: -8]
        for (byte, expected) in anchors {
            XCTAssertEqual(MuLaw.expand(byte), expected, "expansion wrong at \(byte)")
        }
    }

    /// Compression is lossy by design, but logarithmically: the error has to stay
    /// small RELATIVE to the sample, across the whole range, not just near zero.
    func testRoundTripStaysWithinMuLawQuantisation() {
        var worst = 0.0
        for value in stride(from: -32768, through: 32767, by: 257) {
            let sample = Int16(value)
            let back = MuLaw.expand(MuLaw.compress(sample))
            let error = abs(Double(back) - Double(sample))
            if abs(value) > 100 { worst = max(worst, error / Double(abs(value))) }
        }
        XCTAssertTrue(worst < 0.05, "relative error \(worst) exceeds mu-law quantisation")
    }

    /// Halving the upload is the entire point.
    func testEncodingAWAVHalvesIt() {
        let samples = (0..<1000).map { Int16(truncatingIfNeeded: $0 * 31) }
        guard let encoded = MuLaw.encodeWAV(wav(samples)) else {
            return XCTFail("a 16 kHz mono 16-bit WAV must encode")
        }
        XCTAssertEqual(encoded.count, samples.count)
    }

    /// Anything not exactly 16 kHz mono 16-bit returns nil so the caller sends
    /// the original. A dictation must never be lost to an encoding problem.
    func testUnexpectedAudioFallsBackRatherThanCorrupting() {
        XCTAssertNil(MuLaw.encodeWAV(Data("not a wav at all".utf8)))
        XCTAssertNil(MuLaw.encodeWAV(Data()))
        XCTAssertNil(MuLaw.encodeWAV(wav([1, 2, 3], rate: 44100)))
        XCTAssertNil(MuLaw.encodeWAV(wav([1, 2, 3], channels: 2)))
    }

    private func wav(_ samples: [Int16], rate: UInt32 = 16000, channels: UInt16 = 1) -> Data {
        var data = Data()
        func put(_ string: String) { data.append(Data(string.utf8)) }
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(samples.count * 2)
        put("RIFF"); put32(36 + payload); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(channels); put32(rate)
        put32(rate * UInt32(channels) * 2); put16(channels * 2); put16(16)
        put("data"); put32(payload)
        for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }
}
