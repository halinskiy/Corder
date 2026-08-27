import Foundation

/// Generates a Loom-style chapter list for a finished transcript via
/// a cheap text-only Gemini call. Returns a handful of chapters with
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

    struct Chapter: Codable, Equatable, Sendable {
        let startMs: Int64
        let title: String
        enum CodingKeys: String, CodingKey {
            case startMs = "start_ms"
            case title
        }
    }

    /// How many chapters a meeting of this length should get: about one per
    /// 5 minutes, never fewer than 2 or more than 12. The model gets this as
    /// a target and the result is thinned to `maxCount` regardless: told
    /// "3 to 8" it returned 28 chapters on a 38-minute call, one every couple
    /// of lines, which is a table of contents, not chapters.
    static func targetCount(durationMs: Int64) -> (target: Int, maxCount: Int) {
        let minutes = Double(max(0, durationMs)) / 60_000.0
        let target = min(12, max(2, Int((minutes / 5.0).rounded())))
        return (target, target + 2)
    }

    /// `segments` carries the per-line timing the model needs. We
    /// stringify them as `[mm:ss] text` and ask Gemini to pick
    /// natural chapter boundaries that line up with topic shifts
    /// rather than fixed time intervals. `durationMs` (the recording
    /// length) sizes the chapter count; without it the last line's
    /// start stands in.
    static func generate(timedLines: [(startMs: Int64, text: String)],
                         durationMs: Int64? = nil) async throws -> [Chapter]? {
        guard !timedLines.isEmpty else { return nil }
        let jwt = await GeminiTranscriber.jwtForProxy()
        let key = GeminiTranscriber.apiKey ?? ""
        if jwt.isEmpty && key.isEmpty { return nil }
        let base = await GeminiTranscriber.endpointBaseForProxy()

        // Prompt lines are TIME BLOCKS of the transcript, about 200 per
        // meeting (15 s each on a 38-minute call, ~36 s on a 2-hour one), so
        // the WHOLE meeting is in view. The old hard `prefix(2000)` silently
        // chaptered only the first ~80 minutes of a long call, and 900+
        // one-sentence lines invited a chapter every couple of lines (28 on a
        // 38-minute call, and the pretty-printed JSON for them overflowed the
        // output budget). A block is a few seconds long, so a chapter start
        // still resolves to within a breath of the real topic shift.
        let lastMs = max(durationMs ?? 0, (timedLines.last?.startMs ?? 0) + 30_000)
        let blockMs = max(15_000, lastMs / 200)
        var grouped: [(startMs: Int64, text: String)] = []
        var blockStart: Int64 = -1
        var blockText: [String] = []
        for line in timedLines {
            // Strip newlines so the prompt stays one-line-per-input; a
            // mid-sentence break reads to the model as a topic shift.
            let text = line.text.replacingOccurrences(of: "\n", with: " ")
            if blockStart < 0 || line.startMs - blockStart >= blockMs {
                if blockStart >= 0 { grouped.append((startMs: blockStart, text: blockText.joined(separator: " "))) }
                blockStart = line.startMs
                blockText = [text]
            } else {
                blockText.append(text)
            }
        }
        if blockStart >= 0 { grouped.append((startMs: blockStart, text: blockText.joined(separator: " "))) }
        guard !grouped.isEmpty else { return nil }

        let (target, maxCount) = targetCount(durationMs: lastMs)
        let minutes = Int(lastMs / 60_000)

        var lines = ""
        for (idx, line) in grouped.enumerated() {
            let s = Int(line.startMs / 1000)
            let mm = s / 60
            let ss = s % 60
            // Prefix each line with its INDEX. The model returns the
            // index where a chapter starts; the server maps that back
            // to the line's real `startMs`. We used to ask for
            // `start_ms` directly with the line tagged `[mm:ss]`, but
            // Gemini Flash Lite (thinkingBudget 0) can't reliably do
            // mm:ss→milliseconds math and returned 0 / seconds /
            // garbage, every chapter rendered as 0:00. Echoing an
            // integer index is mechanical and bulletproof.
            lines += "\(idx) [\(String(format: "%02d:%02d", mm, ss))] \(line.text)\n"
        }

        let system = """
        You generate Loom-style chapters for a meeting transcript.
        Each transcript line is prefixed with its integer INDEX, then
        a [mm:ss] timestamp, then the text.
        Output ONLY a JSON object with a `chapters` array. Each
        chapter has `start_index` (the integer index of the line where
        that chapter begins, copy it exactly from the line prefix)
        and `title` (3–7 words describing the topic of that segment).

        Language: every `title` MUST be in the SAME language as the
        transcript (Russian transcript → Russian titles, English →
        English, and so on). NEVER translate titles into English when
        the transcript is in another language — this is the single most
        common mistake on this task, do not make it. Match the language
        of the line text, not this instruction.

        Rules:
        - The meeting is about \(minutes) minutes long. Return about
          \(target) chapters, one per REAL topic, never more than
          \(maxCount). A chapter spans several minutes (at least 3
          unless the meeting is under 10 minutes); a passing remark or
          a single exchange is not a chapter.
        - The first chapter MUST have start_index 0.
        - Pick natural topic shifts, not fixed time intervals.
        - start_index values must be strictly increasing.
        - Titles describe the SUBSTANCE ("Pricing for the Q3 launch",
          "Hiring freeze decision"), not boilerplate
          ("Introduction", "Discussion", "Next steps").
        - No surrounding text, no markdown, no preamble, JSON only.
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
                // Same disable-thinking trick as GeminiTitler
                // chapter selection is mechanical, not reasoning.
                "thinkingConfig": ["thinkingBudget": 0],
                // A dozen chapters pretty-printed is ~400 tokens; 1024 was
                // hit the moment the model over-chaptered (28+ entries) and
                // the whole tab came up empty. Room for any count, the
                // thinning below caps what is kept.
                "maxOutputTokens": 4096,
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

        // Every failure below is logged: "Chapters didn't work" reports used
        // to arrive with nothing in the log to say why.
        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            guard let h = resp as? HTTPURLResponse else { return nil }
            data = d
            http = h
        } catch {
            FileLogger.log("GeminiChapters: request failed (\(error.localizedDescription))")
            return nil
        }
        // Surface the Worker's tier-gate distinctly (see PaidFeatureError).
        if http.statusCode == 403 { throw PaidFeatureError.tierRequired }
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            FileLogger.log("GeminiChapters: HTTP \(http.statusCode) \(bodyText.prefix(300))")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first else {
            FileLogger.log("GeminiChapters: no candidates in response: \(bodyText.prefix(300))")
            return nil
        }
        let finish = first["finishReason"] as? String ?? "?"
        guard let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            FileLogger.log("GeminiChapters: empty content, finishReason=\(finish)")
            return nil
        }

        let raw = parts.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chaptersArr: [[String: Any]]
        if let inner = raw.data(using: .utf8),
           let payloadObj = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
           let arr = payloadObj["chapters"] as? [[String: Any]] {
            chaptersArr = arr
        } else {
            // Truncated output (MAX_TOKENS) or stray text around the JSON:
            // salvage every complete `{…}` object. The thinning below caps
            // the count anyway, so the chapters that did make it through
            // are the ones that would have been kept.
            let salvaged = Self.completeObjects(in: raw)
            guard !salvaged.isEmpty else {
                FileLogger.log("GeminiChapters: unparseable JSON (finishReason=\(finish)): \(raw.prefix(300))")
                return nil
            }
            FileLogger.log("GeminiChapters: salvaged \(salvaged.count) chapter objects from unparseable output (finishReason=\(finish))")
            chaptersArr = salvaged
        }

        let chapters: [Chapter] = chaptersArr.compactMap { dict in
            guard let title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            // Preferred path: the model returns `start_index` (a line
            // number from the prompt); map it to that line's real
            // `startMs`. Falls back to a raw `start_ms` field for any
            // model that ignores the instruction.
            if let idx = (dict["start_index"] as? Int)
                ?? (dict["start_index"] as? Double).map({ Int($0) }) {
                let clamped = max(0, min(idx, grouped.count - 1))
                return Chapter(startMs: grouped[clamped].startMs, title: title)
            }
            let startMs: Int64
            if let v = dict["start_ms"] as? Int64 { startMs = v }
            else if let v = dict["start_ms"] as? Int { startMs = Int64(v) }
            else if let v = dict["start_ms"] as? Double { startMs = Int64(v) }
            else { return nil }
            return Chapter(startMs: max(0, startMs), title: title)
        }
        guard !chapters.isEmpty else {
            FileLogger.log("GeminiChapters: model returned no usable chapters (finishReason=\(finish))")
            return nil
        }
        let fixed = thinned(chapters, maxCount: maxCount, endMs: lastMs)
        if fixed.count != chapters.count {
            FileLogger.log("GeminiChapters: \(chapters.count) chapters from the model → \(fixed.count) after thinning (target \(target), max \(maxCount))")
        }
        return fixed
    }

    /// Every complete flat `{…}` object in `text`, parsed. Used when the
    /// response as a whole doesn't parse (cut off mid-array).
    static func completeObjects(in text: String) -> [[String: Any]] {
        guard let re = try? NSRegularExpression(pattern: "\\{[^{}]*\\}") else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let data = ns.substring(with: m.range).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj
        }
    }

    /// Enforce the shape the prompt asks for, whatever the model did:
    /// sorted, no two chapters within 45 s of each other, no more than
    /// `maxCount` (the shortest spans go first), the first one at 0:00.
    static func thinned(_ chapters: [Chapter], maxCount: Int, endMs: Int64) -> [Chapter] {
        var out: [Chapter] = []
        for c in chapters.sorted(by: { $0.startMs < $1.startMs }) {
            // A topic does not change every 20 seconds; the second of two
            // near-identical starts is the model splitting hairs.
            if let last = out.last, c.startMs - last.startMs < 45_000 { continue }
            out.append(c)
        }
        // Still over the cap: drop the chapter with the shortest span, never
        // the opening one, until it fits.
        while out.count > max(1, maxCount) {
            var victim = 1
            var shortest = Int64.max
            for k in 1..<out.count {
                let next = k + 1 < out.count ? out[k + 1].startMs : max(endMs, out[k].startMs + 1)
                let span = next - out[k].startMs
                if span < shortest { shortest = span; victim = k }
            }
            out.remove(at: victim)
        }
        // Force the first chapter to start at 00:00, the prompt asks for it,
        // but the earliest transcript line is almost never at 0 ms (VAD
        // projection + pre-roll push it in by hundreds of ms), so we must NOT
        // insert a synthetic chapter (that duplicated the real first chapter's
        // title on nearly every meeting). Snap the earliest chapter to 0 in
        // place instead.
        if let first = out.first, first.startMs != 0 {
            out[0] = Chapter(startMs: 0, title: first.title)
        }
        return out
    }
}
