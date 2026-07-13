import Foundation

/// Granola-style post-processing for raw Whisper turns. We pipe the
/// model's verbatim output through gpt-4o-mini and ask for ONLY
/// punctuation, capitalisation, and obvious typo fixes, no rewording,
/// no summarisation, no translation. Timestamps and speaker labels are
/// preserved 1:1; only `Turn.text` is replaced.
///
/// Why this stage exists: whisper-1 is great at WHAT was said but
/// terrible at how it READS. Sentences fuse, "iPhone" becomes
/// "i phone", proper nouns lowercase, no commas. Running the raw text
/// through a cheap LLM once is the same trick Granola uses, costs
/// ~$0.005/hour of audio, and is opt-in via `AppSettings.transcriptCleanup`.
///
/// Hard rules:
///   • Best-effort only. ANY failure (no key, timeout, 4xx, parse
///     error, line-count mismatch) returns the input unchanged. This
///     stage must NEVER block transcript availability, the worst it
///     can do is no-op.
///   • Same timestamps + speaker labels as the input, full stop. The
///     model is instructed to keep one line per input line; if the
///     count comes back off we treat that as a parse failure.
///   • Gated by `AppSettings.transcriptCleanup` (defaults ON for
///     Whisper users).
@MainActor
enum WhisperCleanup {

    // MARK: - Tunables

    /// Endpoint + model. gpt-4o-mini is the right cost/quality knob
    /// for a "make the text presentable" pass: $0.15 / $0.60 per 1M
    /// tokens, fast, native multilingual. We post chat-completions
    /// rather than the responses API so the surface matches every
    /// other Corder OpenAI call and we can stream later if needed.
    private static let directEndpoint = "https://api.openai.com/v1/chat/completions"
    private static let proxyEndpoint = "https://corder-api.empqwork.workers.dev/transcribe/whisper-cleanup"
    private static let model = "gpt-4o-mini"

    /// Per-call turn budget. 50 short turns ≈ 3-5 k tokens of input,
    /// well under the 16 k context window and small enough that one
    /// flaky response only loses 50 lines of polish (the original
    /// turns are still served, see "best-effort" above).
    private static let maxTurnsPerCall = 50

    /// Cleanup is a luxury. If there's almost nothing to polish, skip
    /// the API entirely so a near-silent recording never pays a
    /// network round-trip.
    private static let minTotalCharsToCall = 30

    // MARK: - Public API

    /// Polishes Whisper turns through gpt-4o-mini. Returns turns with
    /// the same timestamps and speaker labels; only `text` is replaced.
    /// On any failure returns the input unchanged.
    static func polish(_ turns: [GeminiTranscriber.Turn],
                       language: String?) async -> [GeminiTranscriber.Turn] {
        // Setting gate first, a Whisper user who flipped cleanup off
        // shouldn't pay an HTTP round-trip just to be told no.
        guard AppSettings.transcriptCleanup else {
            FileLogger.log("WhisperCleanup: disabled via AppSettings, returning turns unchanged")
            return turns
        }
        guard !turns.isEmpty else { return turns }
        let totalChars = turns.reduce(0) { $0 + $1.text.count }
        guard totalChars >= minTotalCharsToCall else {
            FileLogger.log("WhisperCleanup: only \(totalChars) chars of text, skipping API call")
            return turns
        }

        // Resolve routing once for the whole transcript. When the
        // user is signed in we proxy through the Worker (server-side
        // OpenAI key, tier-gated). Signed-out builds still need a
        // local key file as before, and on that path a missing key
        // is the silent skip it always was.
        let jwt = await Self.jwt()
        let key = readAPIKey() ?? ""
        if jwt.isEmpty && key.isEmpty {
            FileLogger.log("WhisperCleanup: no OpenAI key and not signed in, returning turns unchanged")
            return turns
        }

        // Batched calls preserve order, we never touch a turn outside
        // its own batch, so the global sequence is just batches glued
        // back together.
        var out: [GeminiTranscriber.Turn] = []
        out.reserveCapacity(turns.count)
        var idx = 0
        var batchNo = 0
        while idx < turns.count {
            let end = min(idx + maxTurnsPerCall, turns.count)
            let batch = Array(turns[idx..<end])
            batchNo += 1
            let polished = await polishBatch(batch, language: language,
                                             apiKey: key, jwt: jwt, batchNo: batchNo)
            out.append(contentsOf: polished)
            idx = end
        }
        return out
    }

    private static func jwt() async -> String {
        await MainActor.run {
            SupabaseClientHolder.shared.auth.currentSession?.accessToken ?? ""
        }
    }

    // MARK: - Single batch

    /// One chat-completion call. On any error returns `batch` unchanged
    /// so the global polish is still best-effort per batch (a single
    /// flaky chunk doesn't poison the rest of the transcript).
    private static func polishBatch(_ batch: [GeminiTranscriber.Turn],
                                    language: String?,
                                    apiKey: String,
                                    jwt: String,
                                    batchNo: Int) async -> [GeminiTranscriber.Turn] {
        guard !batch.isEmpty else { return batch }

        let systemPrompt: String = {
            var s = """
            You are a professional transcript editor. Fix punctuation, capitalisation, \
            and obvious typos in the spoken text below. Preserve the original meaning, \
            speaker order, and wording. Do not paraphrase, summarise, translate, or add \
            content. Return ONLY the edited text in the same line structure as the input: \
            one line per input line, no numbering, no prefixes.
            """
            if let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines),
               !lang.isEmpty {
                s += " The transcript language is \(lang)."
            }
            return s
        }()

        // Numbered input lines. We strip newlines from each turn so the
        // 1:1 line correspondence on the way back is unambiguous
        // otherwise a turn containing a literal "\n" would land on two
        // output lines and our parser would mis-align everything that
        // follows.
        var userLines = ""
        for (i, t) in batch.enumerated() {
            let oneLine = t.text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: CharacterSet.whitespaces)
            userLines += "\(i + 1). \(oneLine)\n"
        }

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userLines]
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            FileLogger.log("WhisperCleanup: batch \(batchNo) payload encode failed, returning unchanged")
            return batch
        }

        let useProxy = !jwt.isEmpty
        let endpointURL = useProxy ? proxyEndpoint : directEndpoint
        let authValue = useProxy ? "Bearer \(jwt)" : "Bearer \(apiKey)"
        var req = URLRequest(url: URL(string: endpointURL)!)
        req.httpMethod = "POST"
        req.setValue(authValue, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 90
        req.httpBody = body

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            FileLogger.log("WhisperCleanup: batch \(batchNo) network error (\(error)), returning unchanged")
            return batch
        }

        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            FileLogger.log("WhisperCleanup: batch \(batchNo) HTTP \(status), \(bodyText.prefix(200)), returning unchanged")
            return batch
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            FileLogger.log("WhisperCleanup: batch \(batchNo) parse error, returning unchanged")
            return batch
        }

        let edited = parseNumberedLines(content, expected: batch.count)
        guard edited.count == batch.count else {
            FileLogger.log("WhisperCleanup: batch \(batchNo) line-count mismatch (got \(edited.count) expected \(batch.count)), returning unchanged")
            return batch
        }

        var out: [GeminiTranscriber.Turn] = []
        out.reserveCapacity(batch.count)
        for (i, t) in batch.enumerated() {
            let cleaned = edited[i].trimmingCharacters(in: .whitespaces)
            // Empty polished line is suspect, the model dropped a turn,
            // and we'd rather keep the original than serve a blank.
            let finalText = cleaned.isEmpty ? t.text : cleaned
            out.append(GeminiTranscriber.Turn(speakerLabel: t.speakerLabel,
                                              startMs: t.startMs,
                                              endMs: t.endMs,
                                              text: finalText))
        }
        FileLogger.log("WhisperCleanup: batch \(batchNo) polished \(batch.count) turns")
        return out
    }

    // MARK: - Parsing

    /// Parse "1. text\n2. text\n…" back into an array. Tolerant: the
    /// model occasionally adds a stray blank line or drops the "N. "
    /// prefix on the last line, so we accept both numbered and bare
    /// non-empty lines and only validate the final count at the call
    /// site.
    private static func parseNumberedLines(_ content: String, expected: Int) -> [String] {
        let lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var out: [String] = []
        out.reserveCapacity(expected)
        for line in lines {
            // Strip a leading "N. " or "N) " prefix if the model
            // mirrored our numbering. Otherwise take the line as-is.
            if let range = line.range(of: #"^\d+[\.\)]\s*"#,
                                       options: .regularExpression) {
                out.append(String(line[range.upperBound...]))
            } else {
                out.append(line)
            }
        }
        return out
    }

    // MARK: - API key

    /// Reads the OpenAI API key from the same source `WhisperTranscriber`
    /// Legacy local-key fallback removed, production users go through
    /// the Cloudflare Worker proxy (`/transcribe/whisper-cleanup`) with
    /// their Supabase JWT. The .app never ships an OpenAI key, and the
    /// `~/.config/corder/openai_key` file is no longer read so we can
    /// stop documenting a path that distributes the project's billing
    /// risk onto every install. Returning nil keeps the call-site
    /// signature stable; pipeline already falls through to whisperLocal
    /// when the cleanup step is unreachable.
    private static func readAPIKey() -> String? { nil }
}
