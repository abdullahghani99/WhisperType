import Foundation

final class MockHTTP: URLProtocol {
    static var code = 200
    static var body = Data("{}".utf8)
    static var seen: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.code, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main enum TransportTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTTP.self]
        let client = ServerClient(baseURL: URL(string: "http://test.invalid")!, apiKey: "test-only", session: URLSession(configuration: configuration))
        var checks = 0
        for code in [401,403,404,429,500,503] {
            MockHTTP.code = code; MockHTTP.body = Data("{\"detail\":\"test failure\"}".utf8)
            let operations: [() async throws -> Void] = [
                { _ = try await client.health() }, { try await client.addVocab(terms: ["Atlas"]) },
                { _ = try await client.meetings() }, { _ = try await client.getVocab() },
                { _ = try await client.recent() }, { _ = try await client.suggestions() }]
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
        print("Transport tests passed: \(checks) status/schema checks, authenticated requests, no network.")
    }
}
