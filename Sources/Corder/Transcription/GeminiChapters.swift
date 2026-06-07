import Foundation

/// Generates a Loom-style chapter list for a finished transcript via
/// a cheap text-only Gemini call. Returns 3–8 chapters with
/// `start_ms` timestamps and short titles, ready to render as a
/// clickable third tab next to Transcript / Summary.
///
/// Routing mirrors GeminiTitler / GeminiSummarizer: a signed-in
/// user goes through the Cloudflare Worker proxy (server-side
/// Google key, JWT auth, tier-gated). A signed-out build / dev
/// shell falls back to the local key file. Best-effort: any failure
/// returns nil and the UI shows an "no chapters yet" placeholder.
enum GeminiChapters {
    private static let model = "gemini-2.5-flash-lite"

    struct Chapter: Codable, Equatable {
        let startMs: Int64
        let title: String
        enum CodingKeys: String, CodingKey {
            case startMs = "start_ms"
            case title
        }
    }

    /// `segments` carries the per-line timing the model needs. We
    /// stringify them as `[mm:ss] text` and ask Gemini to pick
    /// natural chapter boundaries that line up with topic shifts
    /// rather than fixed time intervals.
    static func generate(timedLines: [(startMs: Int64, text: String)]) async -> [Chapter]? {
        guard !timedLines.isEmpty else { return nil }
        let jwt = await GeminiTranscriber.jwtForProxy()
        let key = GeminiTranscriber.apiKey ?? ""
        if jwt.isEmpty && key.isEmpty { return nil }
        let base = await GeminiTranscriber.endpointBaseForProxy()

        // Cap the prompt — Gemini Flash Lite gives stable chapter
        // judgements from ~200 lines, and stuffing a 2-hour
        // transcript would blow the input window without improving
        // the output.
        let trimmed = Array(timedLines.prefix(2000))
        var lines = ""
        for (idx, line) in trimmed.enumerated() {
            let s = Int(line.startMs / 1000)
            let mm = s / 60
            let ss = s % 60
            // Strip newlines from the line so the prompt stays one-
            // line-per-input — keeps the model from misreading
            // mid-sentence breaks as topic shifts.
            let clean = line.text.replacingOccurrences(of: "\n", with: " ")
            // Prefix each line with its INDEX. The model returns the
            // index where a chapter starts; the server maps that back
            // to the line's real `startMs`. We used to ask for
            // `start_ms` directly with the line tagged `[mm:ss]`, but
            // Gemini Flash Lite (thinkingBudget 0) can't reliably do
            // mm:ss→milliseconds math and returned 0 / seconds /
            // garbage — every chapter rendered as 0:00. Echoing an
            // integer index is mechanical and bulletproof.
            lines += "\(idx) [\(String(format: "%02d:%02d", mm, ss))] \(clean)\n"
        }

        let system = """
        You generate Loom-style chapters for a meeting transcript.
        Each transcript line is prefixed with its integer INDEX, then
        a [mm:ss] timestamp, then the text.
        Output ONLY a JSON object with a `chapters` array. Each
        chapter has `start_index` (the integer index of the line where
        that chapter begins — copy it exactly from the line prefix)
        and `title` (3–7 words describing the topic of that segment in
        the SAME language as the transcript).

        Rules:
        - 3 to 8 chapters depending on how long / topically varied
          the transcript is. Short calls (under 5 min) get 2–3.
        - The first chapter MUST have start_index 0.
        - Pick natural topic shifts, not fixed time intervals.
        - start_index values must be strictly increasing.
        - Titles describe the SUBSTANCE ("Pricing for the Q3 launch",
          "Hiring freeze decision"), not boilerplate
          ("Introduction", "Discussion", "Next steps").
        - No surrounding text, no markdown, no preamble — JSON only.
        - If the transcript has no discernible content, return
          `{"chapters": []}`.
        """

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [[
                "role": "user",
                "parts": [["text": "Transcript:\n\n\(lines)"]]
            ]],
            "generationConfig": [
                "temperature": 0.3,
                // Same disable-thinking trick as GeminiTitler —
                // chapter selection is mechanical, not reasoning.
                "thinkingConfig": ["thinkingBudget": 0],
                "maxOutputTokens": 1024,
                "responseMimeType": "application/json"
            ]
        ]

        guard let url = URL(string: "\(base)/models/\(model):generateContent?key=\(key)"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !jwt.isEmpty {
            req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 60
        req.httpBody = payload

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }

        let raw = parts.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let inner = raw.data(using: .utf8),
              let payloadObj = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
              let chaptersArr = payloadObj["chapters"] as? [[String: Any]] else { return nil }

        let chapters: [Chapter] = chaptersArr.compactMap { dict in
            guard let title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            // Preferred path: the model returns `start_index` (a line
            // number from the prompt); map it to that line's real
            // `startMs`. Falls back to a raw `start_ms` field for any
            // model that ignores the instruction.
            if let idx = (dict["start_index"] as? Int)
                ?? (dict["start_index"] as? Double).map({ Int($0) }) {
                let clamped = max(0, min(idx, trimmed.count - 1))
                return Chapter(startMs: trimmed[clamped].startMs, title: title)
            }
            let startMs: Int64
            if let v = dict["start_ms"] as? Int64 { startMs = v }
            else if let v = dict["start_ms"] as? Int { startMs = Int64(v) }
            else if let v = dict["start_ms"] as? Double { startMs = Int64(v) }
            else { return nil }
            return Chapter(startMs: max(0, startMs), title: title)
        }
        // Drop anything past the last real line and force a 00:00 first
        // chapter — the prompt asks for it, but a stray model can drift.
        guard !chapters.isEmpty else { return nil }
        var fixed = chapters.sorted { $0.startMs < $1.startMs }
        if fixed.first?.startMs != 0 {
            fixed.insert(Chapter(startMs: 0, title: fixed.first?.title ?? "Start"), at: 0)
        }
        return fixed
    }
}
