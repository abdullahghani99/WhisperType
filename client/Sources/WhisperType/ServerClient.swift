import Foundation

/// Talks to the WhisperType server.
struct ServerClient {
    let baseURL: URL
    let apiKey: String?

    struct Result {
        let raw: String
        let text: String
    }

    /// GET /health — used at startup to verify reachability + ATS from inside
    /// the app process (curl bypasses App Transport Security; URLSession does not).
    func health() async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 8
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        return "HTTP \(code): \(String(data: data, encoding: .utf8) ?? "")"
    }

    struct Vocab {
        var replacements: [String: String] = [:]
        var terms: [String] = []
        var snippets: [String: String] = [:]
    }

    /// Fetch the server's current vocabulary/dictionary.
    func getVocab() async throws -> Vocab {
        var req = URLRequest(url: baseURL.appendingPathComponent("vocab"))
        req.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return Vocab(
            replacements: obj["replacements"] as? [String: String] ?? [:],
            terms: obj["terms"] as? [String] ?? [],
            snippets: obj["snippets"] as? [String: String] ?? [:])
    }

    /// Merge additions into the server vocabulary (add-only).
    func addVocab(replacements: [String: String] = [:], terms: [String] = [],
                  snippets: [String: String] = [:]) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("vocab"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "replacements": replacements, "terms": terms, "snippets": snippets,
        ])
        req.timeoutInterval = 10
        _ = try await URLSession.shared.data(for: req)
    }

    /// Fetch recent dictations (polished text) for the menu-bar history list.
    func recent(limit: Int = 15) async throws -> [String] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("history"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let items = obj["items"] as? [[String: Any]] ?? []
        return items.compactMap { ($0["polished"] as? String) ?? ($0["corrected"] as? String) }
            .filter { !$0.isEmpty }
    }

    /// POST the WAV to /WhisperType and return the polished transcript.
    func transcribe(wav: Data) async throws -> Result {
        let boundary = "vf-\(UUID().uuidString)"
        var req = URLRequest(url: baseURL.appendingPathComponent("dictate"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey = apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 60

        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        add("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        add("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "whispertype", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "server error: \(msg)"])
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return Result(raw: obj["raw"] as? String ?? "",
                      text: obj["text"] as? String ?? "")
    }
}
