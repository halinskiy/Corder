import Foundation

/// Sends Whisper-produced segments to Gemini Flash for cleanup. The model
/// returns the same number of cleaned strings — one per segment — so we can
/// store the result in `segments.text_boost` and let the existing
/// TranscriptPane render the polished version with the original speaker
/// avatars and timestamps.
enum BoostService {
    enum BoostError: Error, LocalizedError {
        case missingAPIKey
        case http(Int, String)
        case noContent
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:    return "Gemini API key is not configured."
            case .http(let s, let body): return "Gemini API \(s): \(body.prefix(220))"
            case .noContent:        return "Gemini returned no content."
            case .decode(let m):    return "Failed to decode response: \(m)"
            }
        }
    }

    /// Boost runs on Gemini 2.5 Pro — slower and more expensive than Flash
    /// (~3-4× cost) but materially better at preserving speaker register and
    /// fixing recognition errors in mixed-language transcripts. Transcription
    /// itself stays on Flash; the per-segment polish pass is where the
    /// quality jump shows up because Pro reasons about full sentence context.
    private static let model = "gemini-2.5-pro"

    static var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !env.isEmpty {
            return env
        }
        let path = ("~/.config/corder/gemini_key" as NSString).expandingTildeInPath
        if let data = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Polishes each segment's text in place. Returns a dictionary mapping
    /// segment id → polished text (or unchanged if Gemini didn't mention it).
    static func boostSegments(_ segments: [(id: Int64, text: String)]) async throws -> [Int64: String] {
        guard let key = apiKey else { throw BoostError.missingAPIKey }
        guard !segments.isEmpty else { return [:] }

        // Build the input as a numbered list. Using ids keeps the mapping stable
        // even when Gemini decides to merge or skip a line.
        let numbered = segments.map { "\($0.id): \($0.text)" }.joined(separator: "\n")

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)"
        guard let url = URL(string: urlString) else {
            throw BoostError.decode("invalid URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 120

        let system = """
        You polish raw speech-to-text segments from a meeting recorder (Russian + English mix).
        You will receive a list of segments, one per line, in the form "ID: text".
        Return JSON with the same IDs and a polished version of each text.

        Polishing rules:
        - Restore punctuation and capitalisation.
        - Fix obvious recognition errors based on context (e.g. "пермь" → "Whisper", "кода" → "Claude" if speaker is talking about an AI, "кордор" → "Corder").
        - Remove filler / stutters (ну, э-э, типа, вот) ONLY when they don't carry meaning.
        - Do NOT translate. Russian stays Russian, English stays English.
        - Preserve roughly the same length — don't merge or split segments.
        - If a segment is already perfect, return it unchanged.

        Output STRICT JSON only, in this shape:
        { "segments": [ { "id": 123, "text": "polished text" }, ... ] }
        Include every input id. No prose, no markdown fence.
        """

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": system]]
            ],
            "contents": [[
                "role": "user",
                "parts": [["text": numbered]]
            ]],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 16384,
                "responseMimeType": "application/json"
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BoostError.http(0, String(data: data, encoding: .utf8) ?? "")
        }
        if !(200..<300).contains(http.statusCode) {
            throw BoostError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        // Gemini returns: { candidates: [{ content: { parts: [{ text: <JSON string> }] } }] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw BoostError.decode("unexpected response shape: \(String(data: data, encoding: .utf8)?.prefix(220) ?? "")")
        }
        let raw = parts
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw BoostError.noContent }

        guard let payloadData = raw.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let segs = payload["segments"] as? [[String: Any]] else {
            throw BoostError.decode("Could not parse segments JSON: \(raw.prefix(180))")
        }

        var out: [Int64: String] = [:]
        for s in segs {
            let id: Int64?
            if let n = s["id"] as? Int64 { id = n }
            else if let n = s["id"] as? Int { id = Int64(n) }
            else if let str = s["id"] as? String { id = Int64(str) }
            else { id = nil }
            guard let i = id, let t = s["text"] as? String else { continue }
            out[i] = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }
}
