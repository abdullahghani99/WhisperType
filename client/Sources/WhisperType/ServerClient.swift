import Foundation

/// Talks to the WhisperType server.
struct ServerClient {
    let baseURL: URL
    let apiKey: String?

    struct Result {
        let id: Int?      // history row id — used to teach a correction later
        let raw: String
        let text: String
    }

    /// A learning candidate the server derived from a correction or history scan.
    struct Suggestion: Identifiable {
        let id: Int
        let kind: String      // "replacement" | "term"
        let from: String      // replacement source (heard); "" for terms
        let to: String        // replacement target, or the term itself
        let count: Int
        let source: String    // "edit" | "scan"

        /// Human-readable one-liner for the Learning list.
        var label: String {
            kind == "replacement" ? "\(from) → \(to)" : "Add term: \(to)"
        }
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

    /// Prompt mode result: two engineered prompts from one rough dictation.
    struct Engineered {
        let raw: String
        let concise: String
        let detailed: String
    }

    /// POST the WAV to /engineer (prompt mode) — returns a concise and a detailed
    /// engineered prompt built from the rough spoken request.
    func engineer(wav: Data) async throws -> Engineered {
        let boundary = "vf-\(UUID().uuidString)"
        var req = URLRequest(url: baseURL.appendingPathComponent("engineer"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey = apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 300
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
            throw NSError(domain: "whispertype", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "server error: \(msg)"])
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return Engineered(raw: obj["raw"] as? String ?? "",
                          concise: obj["concise"] as? String ?? "",
                          detailed: obj["detailed"] as? String ?? "")
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
        // Long dictations take a while to transcribe on the server; a short
        // timeout silently drops them. Allow up to 5 minutes.
        req.timeoutInterval = 300

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "whispertype", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "server error: \(msg)"])
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return Result(id: obj["id"] as? Int,
                      raw: obj["raw"] as? String ?? "",
                      text: obj["text"] as? String ?? "")
    }

    /// Helper: POST JSON to a path with the optional bearer token.
    private func postJSON(_ path: String, _ body: [String: Any]) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "whispertype", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "server error: \(msg)"])
        }
    }

    // MARK: - Learning loop

    /// Teach the server your fix for a dictation. It stores it and derives
    /// candidate vocab corrections (surfaced via `suggestions()`).
    func correct(id: Int, edited: String) async throws {
        try await postJSON("correct", ["id": id, "edited": edited])
    }

    /// Pending learning candidates, most-corrected first.
    func suggestions(limit: Int = 50) async throws -> [Suggestion] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("suggestions"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let items = obj["items"] as? [[String: Any]] ?? []
        return items.compactMap { d in
            guard let id = d["id"] as? Int, let kind = d["kind"] as? String,
                  let to = d["to_val"] as? String else { return nil }
            return Suggestion(id: id, kind: kind, from: d["frm"] as? String ?? "",
                              to: to, count: d["count"] as? Int ?? 1,
                              source: d["source"] as? String ?? "")
        }
    }

    /// Approve a candidate → merges it into the live vocabulary.
    func promoteSuggestion(id: Int) async throws {
        try await postJSON("suggestions/promote", ["id": id])
    }

    /// Reject a candidate so it never resurfaces.
    func dismissSuggestion(id: Int) async throws {
        try await postJSON("suggestions/dismiss", ["id": id])
    }
}
