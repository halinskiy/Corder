import Foundation

/// Generates a Markdown meeting summary from a finished transcript via
/// a text-only Gemini call. Heavier than the title (longer input +
/// output) so it runs on demand — only when the user opens the Summary
/// tab — and the result is cached on the meeting row.
///
/// Best-effort: any failure returns nil and the UI shows a retry state.
enum GeminiSummarizer {
    // flash-lite: a short plain-prose recap doesn't need full Flash;
    // ~3–5× cheaper on text with no meaningful quality loss here.
    private static let model = "gemini-2.5-flash-lite"
    private static let endpoint = "https://generativelanguage.googleapis.com/v1beta"

    static func generate(transcript: String) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let key = GeminiTranscriber.apiKey else { return nil }

        // Summaries need broad context; cap generously but bound it so a
        // 3-hour transcript can't blow the request up.
        let snippet = String(trimmed.prefix(60000))

        let system = """
        You summarise meeting transcripts. Write in the SAME language as
        the transcript (Russian → Russian, English → English).

        Hard rules:
        - Plain prose ONLY. Ordinary paragraphs. Short and to the point.
        - NO lists, NO bullets, NO numbered items, NO headings, NO
          Markdown, NO bold, NO labels like "Decisions:" — just sentences.
        - 1 to 3 short paragraphs total. No filler, no preamble, no
          meta-commentary ("This meeting was about…"). Get straight to
          the substance: what was discussed and what was decided.
        - Be specific and concrete; never invent anything not said.
        """
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [[
                "role": "user",
                "parts": [["text": "Transcript:\n\n\(snippet)"]]
            ]],
            "generationConfig": [
                "temperature": 0.3,
                // Summarisation here is condensation, not multi-step
                // reasoning; thinking just burns output-priced tokens
                // (and on a long transcript can starve the 600-token
                // budget, returning an empty summary).
                "thinkingConfig": ["thinkingBudget": 0],
                "maxOutputTokens": 600
            ]
        ]

        guard let url = URL(string: "\(endpoint)/models/\(model):generateContent?key=\(key)"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 90
        req.httpBody = payload

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }

        let raw = parts.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return raw
    }
}
