import Foundation

enum PaidFeatureError: Error { case tierRequired }

/// Shared recap prompt and output policy for cloud and local transports.
enum GeminiSummarizer {
    static func generate(transcript: String, languageISO: String? = nil,
                         llm: any TextLLM = GeminiTextLLM(channel: .summary)) async throws -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let snippet = TranscriptSampling.evenSample(trimmed, budget: 120000, windows: 8)
        let system = MeetingNotes.languageInstruction(languageISO) + "\n\n" + """
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
          dash. Never write em or en dashes in the output.
        - Bold key numbers, names, decisions, dates, percentages with
          `**…**`.
        - Order sections the way the meeting weighted them: what took the
          most time and what was decided first, tangents last.

        Content rules:
        - Be specific. Numbers, names, dates, deadlines, percentages,
          counts, tool and product names, references someone cited, the
          concrete example given: KEEP them ("обсуждали зарплаты" ❌ →
          "сошлись на зарплате **£35k фикс**" ✅). These specifics are
          the whole reason someone reads the recap instead of the call;
          a bullet that survives without them was not worth writing.
        - Synthesise, do not transcribe. A bullet states WHAT holds, not
          who uttered it; no "Speaker 2 сказал…" / "Speaker 1 ответил…"
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
        - People: refer to a named speaker by first name as written in
          the transcript (a "Kostiantyn Halynskyi" line is "Kostiantyn";
          never bolt a Russian case ending onto a Latin name, rephrase
          instead). An unnamed speaker keeps their label EXACTLY as in
          the transcript ("Speaker 2"), never translated or renumbered,
          so it matches the transcript view.
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
        guard var result = try await llm.complete(system: system, transcript: snippet, maxOutputTokens: 4000, json: false) else { return nil }
        if result.truncated {
            FileLogger.log("MeetingNotes: recap output reached 4000 tokens, retrying with 8000")
            if let again = try await llm.complete(system: system, transcript: snippet, maxOutputTokens: 8000, json: false) {
                result = again
            }
        }
        var text = result.text
        if result.truncated {
            if llm is LocalTextLLM { throw LocalTextLLM.Failure.outputTruncated }
            if let nl = text.lastIndex(of: "\n") {
                text = String(text[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !text.isEmpty else { return nil }
        if llm is LocalTextLLM, !Routes.isStructuredMarkdown(text) { throw LocalTextLLM.Failure.invalidResponse }
        return text
    }
}
