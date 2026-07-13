import Foundation

/// Thrown by a paid-feature generator (Summary / Chapters) when the Worker
/// returns HTTP 403 — a tier gate, NOT a generic failure. The route maps it
/// to a real 403 so the frontend shows the Upgrade upsell instead of the
/// "didn't work, send a report" error card. A 403 is an upsell, never a
/// failure card.
enum PaidFeatureError: Error { case tierRequired }

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

    static func generate(transcript: String) async throws -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Same routing as GeminiTranscriber / GeminiTitler — go
        // through the Worker proxy when signed in so Pro / Max users
        // get auto-summary without needing a local Google API key.
        let jwt = await GeminiTranscriber.jwtForProxy()
        let key = GeminiTranscriber.apiKey ?? ""
        if jwt.isEmpty && key.isEmpty { return nil }
        let base = await GeminiTranscriber.endpointBaseForProxy()

        // Summaries need broad context; cap generously but bound it so a
        // 3-hour transcript can't blow the request up.
        let snippet = String(trimmed.prefix(60000))

        // Prose-style recap. Earlier version used heavy nested bullets
        // ("Speaker 2 said X, Speaker 2 said Y…") which read as a
        // transcript dump rather than a summary. New format: each
        // section is a single flowing paragraph that captures the
        // SUBSTANCE of what was discussed, not a per-speaker log.
        // Bullets reserved only for the trailing "next steps" section
        // where they're genuinely useful (one action per line).
        let system = """
        You write meeting recaps in Markdown. Quality bar: a senior PM
        reading the recap (instead of the call) walks away with what
        was decided, what positions were taken, and the numbers that
        mattered.

        Language: write in the SAME language as the transcript
        (Russian → Russian, English → English). Headings too — never
        English headings under a Russian transcript.

        Output format (STRICT):
        - Markdown only. NO preamble, NO meta ("This meeting was about…"),
          NO closing remarks, NO ```code``` fences.
        - 3 to 6 sections, each headed by `### Heading`. Heading is a
          concrete topic ("Финансовое положение компании", "Решение
          по найму", "Позиция по войне"), NOT a generic label.
        - Body of each section is ONE OR TWO PARAGRAPHS of plain prose.
          DO NOT use bullet lists inside sections. Each paragraph is a
          flowing summary of the substance, written in third person
          past tense ("Обсуждение свелось к тому, что…", "Стороны
          разошлись в оценке…", "Команда решила…").
        - Bold key numbers, names, decisions, dates, percentages with
          `**…**`.
        - Order sections by importance: decisions and money first,
          context and tangents last.

        Content rules:
        - Be specific. Numbers, names, dates, deadlines, percentages,
          counts — keep them inline in the prose, never paraphrase
          them away ("обсуждали зарплаты" ❌ → "сошлись на зарплате
          **£35k фикс**" ✅).
        - Synthesise, do not transcribe. Capture each side's POSITION
          on a topic in one sentence rather than listing every "Speaker
          2 сказал…" / "Speaker 1 ответил…". If both sides agree,
          state the agreement; if they disagreed, state the split in
          one sentence ("Стороны разошлись в оценке X: один считал
          A, другой — B").
        - Never invent anything not said. If unclear, omit it. Do not
          hedge ("вероятно", "возможно") — either it was said or it
          wasn't.
        - Quotes only when exact wording matters. Russian guillemets
          «…» for Russian.
        - ONLY EXCEPTION to the no-bullets rule: a closing section
          `### Дальше` (RU) / `### Next` (EN) listing action items as
          bullets, one per line, responsible party in **bold** when
          known. Skip this section entirely if there are no action
          items.

        Example structure (Russian):

        ### Финансовое положение компании
        Денег осталось на **2 месяца** при текущем burn rate. На прошлой
        неделе сократили **3 подрядчиков**, параллельно ведут переговоры
        с инвестором X о **bridge round £200k**, решение по которому
        ожидается до **15 июня**.

        ### Решение по найму
        Senior backend закрыли на **£70k фикс + 0.5% equity**, выход
        с **1 июля**. От junior-кандидата отказались из-за слабого
        алгоритмического собеса.

        ### Дальше
        - **Костя**: подготовить cap-table к пятнице
        - **Михаил**: встреча с инвестором X в понедельник
        """
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [[
                "role": "user",
                "parts": [["text": "Transcript:\n\n\(snippet)"]]
            ]],
            "generationConfig": [
                "temperature": 0.35,
                // Structured Markdown is a one-shot rewrite, not a chain
                // of reasoning — thinking budget burns output tokens for
                // no quality gain on this kind of task. Output budget is
                // generous (was 600) because a real structured recap of a
                // 30-minute call needs ~1200–2000 tokens.
                "thinkingConfig": ["thinkingBudget": 0],
                "maxOutputTokens": 2200
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
        req.timeoutInterval = 90
        req.httpBody = payload

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        // Surface the Worker's tier-gate distinctly so the route returns a
        // real 403 → Upgrade upsell, not a generic "generation failed".
        if http.statusCode == 403 { throw PaidFeatureError.tierRequired }
        guard (200..<300).contains(http.statusCode),
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
