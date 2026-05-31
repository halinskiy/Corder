import Foundation

/// Generates a short human headline for a finished transcript via a
/// cheap text-only Gemini call (one tiny request, ~tens of output
/// tokens — negligible cost vs. the audio transcription itself).
///
/// Best-effort: any failure returns nil and the UI falls back to the
/// date label, so a flaky network never blocks a transcript.
enum GeminiTitler {
    // flash-lite: a 3–7 word headline doesn't need full Flash; lite is
    // ~3–5× cheaper on text with no meaningful quality loss here.
    private static let model = "gemini-2.5-flash-lite"
    private static let endpoint = "https://generativelanguage.googleapis.com/v1beta"

    static func generate(transcript: String) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Match GeminiTranscriber's routing: a signed-in user goes
        // through the Worker proxy (server-side Google key, JWT
        // auth). A local key file is required ONLY when no Supabase
        // session is around (dev / signed-out builds).
        let jwt = await GeminiTranscriber.jwtForProxy()
        let key = GeminiTranscriber.apiKey ?? ""
        if jwt.isEmpty && key.isEmpty { return nil }
        let base = await GeminiTranscriber.endpointBaseForProxy()

        // Cap the input — a title only needs the gist, and the opening
        // minutes carry the topic. Keeps the call fast and cheap.
        let snippet = String(trimmed.prefix(6000))

        let system = """
        You write a short, descriptive title for a meeting transcript.
        Output ONLY the title — nothing else.

        Rules:
        - Say WHAT the conversation is about (the concrete topic/subject),
          or WHO it is with if that's the point. Infer the subject from
          what is actually discussed.
        - ALWAYS produce a real title whenever there is any discernible
          topic, even from a short or rough transcript. Be decisive.
        - 3 to 7 words. Same language as the transcript (Russian → Russian,
          English → English). No surrounding quotes, no trailing
          punctuation, no "Meeting"/"Conversation"/"Discussion" filler,
          no single bare word copied verbatim from the transcript.
        - Output exactly NONE only when the transcript has no speech or
          no content at all to title (pure noise / empty).
        """
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [[
                "role": "user",
                "parts": [["text": "Transcript:\n\n\(snippet)"]]
            ]],
            "generationConfig": [
                "temperature": 0.3,
                // gemini-2.5-flash is a *thinking* model: with a tiny
                // maxOutputTokens the reasoning pass eats the entire
                // budget and the response comes back with NO text part
                // (finishReason MAX_TOKENS) — which is why every title
                // was silently dropped. Disable thinking for this
                // trivial task and leave generous room for the title.
                "thinkingConfig": ["thinkingBudget": 0],
                "maxOutputTokens": 40
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
        req.timeoutInterval = 30
        req.httpBody = payload

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }

        let raw = parts.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip stray wrapping quotes / trailing period the model
        // sometimes adds despite the instruction.
        let cleaned = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”.").union(.whitespacesAndNewlines))
        // Reject junk: the model's "I can't title this" sentinel, or a
        // degenerate one-word/too-short answer on a thin transcript
        // (the "Го" / "Э" garbage). Returning nil makes the UI fall back
        // to the date label instead of showing a nonsense title.
        let words = cleaned.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard !cleaned.isEmpty,
              cleaned.count <= 80,
              cleaned.uppercased() != "NONE",
              words.count >= 2,
              cleaned.count >= 6
        else { return nil }
        return cleaned
    }
}
