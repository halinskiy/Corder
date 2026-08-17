import Foundation

/// Thrown by a paid-feature generator (Summary / Chapters) when the Worker
/// returns HTTP 403, a tier gate, NOT a generic failure. The route maps it
/// to a real 403 so the frontend shows the Upgrade upsell instead of the
/// "didn't work, send a report" error card. A 403 is an upsell, never a
/// failure card.
enum PaidFeatureError: Error { case tierRequired }

/// Generates a Markdown meeting summary from a finished transcript via
/// a text-only Gemini call. Heavier than the title (longer input +
/// output) so it runs on demand, only when the user opens the Summary
/// tab, and the result is cached on the meeting row.
///
/// Best-effort: any failure returns nil and the UI shows a retry state.
enum GeminiSummarizer {
    // flash-lite: a short plain-prose recap doesn't need full Flash;
    // ~3–5× cheaper on text with no meaningful quality loss here.
    private static let model = "gemini-2.5-flash-lite"

    static func generate(transcript: String) async throws -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Same routing as GeminiTranscriber / GeminiTitler, go
        // through the Worker proxy when signed in so Pro / Max users
        // get auto-summary without needing a local Google API key.
        let jwt = await GeminiTranscriber.jwtForProxy()
        let key = GeminiTranscriber.apiKey ?? ""
        if jwt.isEmpty && key.isEmpty { return nil }
        let base = await GeminiTranscriber.endpointBaseForProxy()

        // Summaries need broad context; cap generously but bound it so a
        // 3-hour transcript can't blow the request up. Over the cap we SAMPLE
        // across the whole meeting rather than crop the head — a recap of a
        // 3-hour call that silently stops at minute 90 is worse than one that
        // is thin everywhere (see `TranscriptSampling`).
        let snippet = TranscriptSampling.evenSample(trimmed, budget: 120000, windows: 8)

        // Dense nested bullets, one fact per line. History: v1 was a
        // per-speaker bullet log ("Speaker 2 said X, Speaker 2 said Y…"),
        // which read as a transcript dump, so v2 swung to flowing prose
        // paragraphs. Prose turned out to cost DETAIL — measured against
        // Granola's notes on the same 65-minute call (2026-08-17): they kept
        // the reference titles, the per-item decisions and the one-line bugs,
        // ours dissolved them into "стороны пришли к соглашению о
        // необходимости…". A recap is read for exactly those specifics.
        // v3 keeps the per-fact bullet SHAPE of v1 but bans the per-speaker
        // logging that made it a dump: each bullet is a decision, a fact or a
        // number, never "кто что сказал".
        let system = """
        You write meeting recaps in Markdown. Quality bar: a senior PM
        reading the recap (instead of the call) walks away with what
        was decided, what positions were taken, and the numbers that
        mattered.

        Language: write in the SAME language as the transcript
        (Russian → Russian, English → English). Headings too, never
        English headings under a Russian transcript.

        Output format (STRICT):
        - Markdown only. NO preamble, NO meta ("This meeting was about…"),
          NO closing remarks, NO ```code``` fences.
        - 4 to 8 sections, each headed by `### Heading`. Heading is a
          concrete topic ("Финансовое положение компании", "Решение
          по найму", "Навигация: шапка сайта"), NOT a generic label.
        - Body of each section is a BULLET LIST, never prose paragraphs.
          One fact, decision or number per bullet.
        - Nest ONE level with exactly two spaces when bullets belong to
          the line above: options under a decision, per-item detail under
          a category, consequences under a problem.
        - Bullets are TELEGRAPHIC. Write the substance, not the fact that
          it was discussed: "Блок «Popular Visa Services» убрать: дублирует
          «Our Immigration Services»" ✅, "Обсуждение свелось к
          необходимости реструктуризации" ❌. Never open a bullet with
          "Обсуждалось", "Стороны пришли", "Было решено рассмотреть".
        - Punctuation: use a colon or a comma where you would reach for a
          dash. Never write an em dash (—) in the output.
        - Bold key numbers, names, decisions, dates, percentages with
          `**…**`.
        - Order sections the way the meeting weighted them: what took the
          most time and what was decided first, tangents last.

        Content rules:
        - Be specific. Numbers, names, dates, deadlines, percentages,
          counts, tool and product names, references someone cited, the
          concrete example given — KEEP them ("обсуждали зарплаты" ❌ →
          "сошлись на зарплате **£35k фикс**" ✅). These specifics are
          the whole reason someone reads the recap instead of the call;
          a bullet that survives without them was not worth writing.
        - Synthesise, do not transcribe. A bullet states WHAT holds, not
          who uttered it — no "Speaker 2 сказал…" / "Speaker 1 ответил…"
          chains. If both sides agreed, state the agreement; if they
          disagreed, state the split in one bullet ("Разошлись в оценке
          X: один считал A, другой B").
        - Cover the WHOLE meeting, not its opening. Every topic that got
          real time deserves a section, including ones raised near the
          end. If the transcript arrives as an even sample (`[…]` marks a
          skipped stretch), weigh all windows equally.
        - Never invent anything not said. If unclear, omit it. Do not
          hedge ("вероятно", "возможно"), either it was said or it
          wasn't.
        - Quotes only when exact wording matters. Russian guillemets
          «…» for Russian.
        - Close with `### Дальше` (RU) / `### Next` (EN) listing action
          items, one per bullet, responsible party in **bold** when it is
          actually known from the transcript. Skip the section entirely
          if there are no action items; never invent an owner.

        Example structure (Russian):

        ### Финансовое положение компании
        - Денег при текущем burn rate осталось на **2 месяца**
        - Сократили **3 подрядчиков** на прошлой неделе
        - Переговоры с инвестором X о **bridge round £200k**
          - Решение ожидается до **15 июня**
          - Запасной вариант: кредитная линия банка, ставка не обсуждалась

        ### Решение по найму
        - Senior backend закрыт: **£70k фикс + 0.5% equity**, выход **1 июля**
        - Junior-кандидату отказали: слабый алгоритмический собес

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
                // of reasoning, thinking budget burns output tokens for
                // no quality gain on this kind of task. Output budget is
                // generous (was 600) because a real structured recap of a
                // 30-minute call needs ~1200–2000 tokens.
                "thinkingConfig": ["thinkingBudget": 0],
                // Bullet recaps of a long call run longer than the prose ones
                // did (Granola's notes on a 65-min call are ~3.5k characters,
                // ≈1.7k Cyrillic tokens), and a truncated recap loses its tail
                // sections silently. 2200 was cutting them off.
                "maxOutputTokens": 4000
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
