import Foundation

final class MockHTTP: URLProtocol {
    static var code = 200
    static var body = Data("{}".utf8)
    static var seen: URLRequest?
    static var seenBody = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen = request
        Self.seenBody = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                precondition(count >= 0, "Could not read intercepted upload")
                if count == 0 { break }
                Self.seenBody.append(contentsOf: buffer.prefix(count))
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.code, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main enum TransportTests {
    // A valid synthetic PCM recording; tests never capture a microphone or
    // contact a server. Include binary bytes to catch accidental text encoding.
    static func recording() -> Data {
        var data = Data()
        func text(_ value: String) { data.append(Data(value.utf8)) }
        func word(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func dword(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        text("RIFF"); dword(3236); text("WAVEfmt "); dword(16)
        word(1); word(1); dword(16000); dword(32000); word(2); word(16)
        text("data"); dword(3200)
        for value in 0..<1600 { word(UInt16(truncatingIfNeeded: value * 101)) }
        return data
    }

    static func assertUpload(path: String, wav: Data) {
        guard let request = MockHTTP.seen,
              let type = request.value(forHTTPHeaderField: "Content-Type"),
              let boundary = type.components(separatedBy: "boundary=").last else {
            preconditionFailure("Audio request missing multipart headers")
        }
        precondition(request.url?.path == path, "Audio sent to the wrong endpoint")
        precondition(request.httpMethod == "POST")
        precondition(request.timeoutInterval == 300)
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
        precondition(type.hasPrefix("multipart/form-data; boundary="))
        // Independent wire expectation, deliberately not AudioUpload.multipart:
        // this must detect call-site drift and changes to the builder itself.
        var expected = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        expected.append(wav)
        expected.append(Data("\r\n--\(boundary)--\r\n".utf8))
        precondition(MockHTTP.seenBody == expected, "Endpoint must receive the original PCM WAV")
    }

    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTTP.self]
        let client = ServerClient(baseURL: URL(string: "http://test.invalid")!, apiKey: "test-only", session: URLSession(configuration: configuration))
        var checks = 0
        let wav = recording()
        for code in [401,403,404,429,500,503] {
            MockHTTP.code = code; MockHTTP.body = Data("{\"detail\":\"test failure\"}".utf8)
            let operations: [() async throws -> Void] = [
                { _ = try await client.health() }, { try await client.addVocab(terms: ["Atlas"]) },
                { _ = try await client.meetings() }, { _ = try await client.getVocab() },
                { _ = try await client.recent() }, { _ = try await client.suggestions() },
                { _ = try await client.transcribe(wav: wav) }, { _ = try await client.engineer(wav: wav) }]
            for operation in operations {
                do { try await operation(); fatalError("HTTP \(code) appeared successful") }
                catch { precondition((error as NSError).code == code); checks += 1 }
                precondition(MockHTTP.seen?.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
            }
        }
        MockHTTP.code = 200
        for body in ["{}", "[]", "{\"items\":[{}]}", "not-json"] {
            MockHTTP.body = Data(body.utf8)
            do { _ = try await client.meetings(); fatalError("Malformed list appeared empty") }
            catch { checks += 1 }
        }
        MockHTTP.body = Data("{\"items\":[]}".utf8)
        let meetings = try await client.meetings()
        precondition(meetings.isEmpty); checks += 1
        MockHTTP.body = Data("{\"status\":\"ok\"}".utf8)
        _ = try await client.health(); checks += 1
        for looped in [false, true] {
            MockHTTP.body = Data("{\"id\":7,\"raw\":\"synthetic source\",\"text\":\"Synthetic result.\",\"transcription_looped\":\(looped)}".utf8)
            let result = try await client.transcribe(wav: wav)
            assertUpload(path: "/dictate", wav: wav)
            precondition(result.looped == looped && result.id == 7)
            precondition(result.raw == "synthetic source" && result.text == "Synthetic result.")
            checks += 1
        }
        MockHTTP.body = Data("{\"raw\":\"synthetic source\",\"concise\":\"Short\",\"detailed\":\"Long\",\"coding\":\"Code\"}".utf8)
        let prompt = try await client.engineer(wav: wav)
        assertUpload(path: "/engineer", wav: wav)
        precondition(prompt.raw == "synthetic source" && prompt.concise == "Short" && prompt.detailed == "Long" && prompt.coding == "Code")
        checks += 1
        for body in ["{}", "[]", "not-json"] {
            MockHTTP.body = Data(body.utf8)
            for operation in [
                { _ = try await client.transcribe(wav: wav) },
                { _ = try await client.engineer(wav: wav) }
            ] {
                do { try await operation(); fatalError("Malformed audio response appeared successful") }
                catch { checks += 1 }
            }
        }
        print("Transport tests passed: \(checks) status/schema/audio checks, authenticated requests, no network.")
    }
}
