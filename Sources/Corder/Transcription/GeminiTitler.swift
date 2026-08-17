import Foundation

/// Generates a short human headline for a finished transcript via a
/// cheap text-only Gemini call (one tiny request, ~tens of output
/// tokens, negligible cost vs. the audio transcription itself).
///
/// Best-effort: any failure returns nil and the UI falls back to the
/// date label, so a flaky network never blocks a transcript.
enum GeminiTitler {
    // flash-lite: a 3–7 word headline doesn't need full Flash; lite is
    // ~3–5× cheaper on text with no meaningful quality loss here.
    private static let model = "gemini-2.5-flash-lite"

    /// Writing system of a piece of text, by majority of its letters.
    /// Used as a deterministic language check on the model's answer: a
    /// Cyrillic transcript must not come back with a Latin title.
    /// Script (not language) is the right granularity here — it is
    /// unambiguous to compute, and it catches the failure users actually
    /// see ("Interface issues and game setup" over a Russian call)
    /// without pretending to identify Kazakh vs Russian (a distinction
    /// NLLanguageRecognizer gets wrong on Cyrillic anyway).
    enum Script: Equatable {
        case cyrillic, latin, cjk, other
    }

    static func dominantScript(_ text: String) -> Script {
        var cyr = 0, lat = 0, cjk = 0
        for s in text.unicodeScalars {
            switch s.value {
            case 0x0400...0x04FF, 0x0500...0x052F: cyr += 1
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: lat += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF: cjk += 1
            default: break
            }
        }
        let total = cyr + lat + cjk
        guard total >= 8 else { return .other }
        if cjk * 2 > total { return .cjk }
        if cyr > lat { return .cyrillic }
        if lat > cyr { return .latin }
        return .other
    }

    static func generate(transcript: String, languageISO: String? = nil) async -> String? {
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

        // Whole transcript when it fits, otherwise an even sample of it (see
        // `TranscriptSampling`, and the cake-title bug it documents). ~24k
        // characters is ≈8k tokens on flash-lite — well under a tenth of a
        // cent per title, so there is no reason to read only the opening.
        let snippet = TranscriptSampling.evenSample(trimmed, budget: 24000)

        // The language rule is stated FIRST and by NAME whenever the
        // pipeline knows it (from the ASR's own per-chunk language
        // tally, the only reliable signal we have). Buried at the end of
        // a rule list as a generic "same language as the transcript" it
        // was routinely ignored: flash-lite with thinking disabled and a
        // 40-token budget defaults to English, so a Russian call came
        // back titled "Interface issues and game setup". A named target
        // language is followed far more reliably than an inferred one.
        let languageLine: String
        if let iso = languageISO?.nilIfEmpty,
           let name = Locale(identifier: "en_US").localizedString(forLanguageCode: iso) {
            languageLine = "- WRITE THE TITLE IN \(name.uppercased()). This is mandatory, the transcript is in \(name)."
        } else {
            languageLine = "- WRITE THE TITLE IN THE TRANSCRIPT'S OWN LANGUAGE (Russian transcript → Russian title, English → English). Never translate to English."
        }
        let system = """
        You write a short, descriptive title for a meeting transcript.
        Output ONLY the title, nothing else.

        Rules:
        \(languageLine)
        - Say WHAT the conversation is about (the concrete topic/subject),
          or WHO it is with if that's the point. Infer the subject from
          what is actually discussed.
        - Title the MAIN SUBJECT of the whole meeting — the thing most of
          the time was spent on, the reason the call happened. Opening
          small talk (greetings, food, cooking, weather, travel, plans for
          the evening) and closing pleasantries are NOT the subject even
          though they come first; ignore them unless the entire call is
          that. Weigh the middle and the end at least as much as the
          opening.
        - The transcript may arrive as an even SAMPLE of the meeting, with
          `[…]` marking a skipped stretch. Judge the subject from all the
          windows together, never from the first one alone.
        - ALWAYS produce a real title whenever there is any discernible
          topic, even from a short or rough transcript. Be decisive.
        - No em dash (—) in the title; use a colon or a comma instead.
        - 3 to 7 words. No surrounding quotes, no trailing punctuation,
          no "Meeting"/"Conversation"/"Discussion" filler, no single bare
          word copied verbatim from the transcript.
        - Output exactly NONE only when the transcript has no speech or
          no content at all to title (pure noise / empty).
        """
        func ask(_ systemPrompt: String) async -> String? {
            let body: [String: Any] = [
                "systemInstruction": ["parts": [["text": systemPrompt]]],
                "contents": [[
                    "role": "user",
                    "parts": [["text": "Transcript:\n\n\(snippet)"]]
                ]],
                "generationConfig": [
                    "temperature": 0.3,
                    // gemini-2.5-flash is a *thinking* model: with a tiny
                    // maxOutputTokens the reasoning pass eats the entire
                    // budget and the response comes back with NO text part
                    // (finishReason MAX_TOKENS), which is why every title
                    // was silently dropped. Disable thinking for this
                    // trivial task and leave generous room for the title.
                    "thinkingConfig": ["thinkingBudget": 0],
                    // 40 was tight for Cyrillic (a 7-word Russian headline
                    // tokenises to ~30), which truncated long titles.
                    "maxOutputTokens": 64
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
            return parts.compactMap { $0["text"] as? String }.joined()
        }

        guard var raw = await ask(system)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        // Deterministic language check. The prompt alone is not enough:
        // the model still drifts to English on a Cyrillic transcript. If
        // the answer's writing system differs from the transcript's, ask
        // once more with the failure named. Script (not language) keeps
        // this honest — it cannot misfire on a Russian/Ukrainian mix the
        // way language identification would.
        let wantScript = Self.dominantScript(snippet)
        if wantScript != .other, Self.dominantScript(raw) != wantScript {
            let scriptName: String
            switch wantScript {
            case .cyrillic: scriptName = "Cyrillic"
            case .cjk: scriptName = "the transcript's East Asian script"
            case .latin: scriptName = "Latin"
            case .other: scriptName = "the transcript's script"
            }
            let stricter = system + """


            IMPORTANT: an earlier attempt answered in the WRONG LANGUAGE
            ("\(raw.prefix(60))"). The transcript is written in \(scriptName).
            Write the title in the transcript's own language, using the same
            script. Do NOT translate it into English.
            """
            if let second = await ask(stricter)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               Self.dominantScript(second) == wantScript {
                FileLogger.log("GeminiTitler: wrong-language title \"\(raw)\" replaced with \"\(second)\"")
                raw = second
            } else {
                FileLogger.log("GeminiTitler: title \"\(raw)\" is off-script and the retry did not fix it, keeping it")
            }
        }
        // Strip stray wrapping quotes / trailing period the model
        // sometimes adds despite the instruction.
        let cleaned = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”.").union(.whitespacesAndNewlines))
        // Reject junk: the model's "I can't title this" sentinel, or a
        // degenerate one-word/too-short answer on a thin transcript
        // (the "Го" / "Э" garbage). Returning nil makes the UI fall back
        // to the date label instead of showing a nonsense title.
        let words = cleaned.split(whereSeparator: { $0 == " " || $0 == "\n" })
        // CJK (Chinese / Japanese) write without inter-word spaces, so a
        // perfectly valid title is one "word", the space-based word count
        // would reject EVERY Chinese/Japanese title and fall back to the date
        // label. Detect Han / Hiragana / Katakana and relax the word-count +
        // char-floor rules for those scripts (Korean uses spaces, unaffected).
        let hasCJK = cleaned.unicodeScalars.contains { s in
            (0x4E00...0x9FFF).contains(s.value) ||   // CJK Unified Ideographs
            (0x3400...0x4DBF).contains(s.value) ||   // CJK Ext A
            (0x3040...0x30FF).contains(s.value)      // Hiragana + Katakana
        }
        guard !cleaned.isEmpty,
              cleaned.count <= 80,
              cleaned.uppercased() != "NONE",
              hasCJK ? cleaned.count >= 2 : (words.count >= 2 && cleaned.count >= 6)
        else { return nil }
        return cleaned
    }
}
