import Foundation

struct TextLLMReply: Sendable {
    let text: String
    let truncated: Bool
}

protocol TextLLM: Sendable {
    func complete(system: String, transcript: String, maxOutputTokens: Int, json: Bool) async throws -> TextLLMReply?
}

struct GeminiTextLLM: TextLLM {
    let channel: NetworkPolicy.Channel

    func complete(system: String, transcript: String, maxOutputTokens: Int, json: Bool) async throws -> TextLLMReply? {
        try NetworkPolicy.require(channel)
        let jwt = await GeminiTranscriber.jwtForProxy()
        let key = GeminiTranscriber.apiKey ?? ""
        guard !jwt.isEmpty || !key.isEmpty else { return nil }
        let base = await GeminiTranscriber.endpointBaseForProxy()
        guard let url = URL(string: "\(base)/models/gemini-2.5-flash-lite:generateContent?key=\(key)") else { return nil }
        var generation: [String: Any] = [
            "temperature": json ? 0.3 : 0.35, "thinkingConfig": ["thinkingBudget": 0],
            "maxOutputTokens": maxOutputTokens
        ]
        if json { generation["responseMimeType"] = "application/json" }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": "Transcript:\n\n\(transcript)"]]]],
            "generationConfig": generation
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !jwt.isEmpty { request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90
        let data: Data
        let response: URLResponse
        do { (data, response) = try await NetworkPolicy.data(for: request, channel: channel) }
        catch {
            FileLogger.log("GeminiTextLLM: \(channel) request failed (\(error.localizedDescription))")
            return nil
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 403 { throw PaidFeatureError.tierRequired }
        guard (200..<300).contains(http.statusCode) else {
            FileLogger.log("GeminiTextLLM: \(channel) HTTP \(http.statusCode)")
            return nil
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidate = (payload["candidates"] as? [[String: Any]])?.first,
              let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            FileLogger.log("GeminiTextLLM: \(channel) invalid response")
            return nil
        }
        let text = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            FileLogger.log("GeminiTextLLM: \(channel) empty response")
            return nil
        }
        return TextLLMReply(text: text, truncated: candidate["finishReason"] as? String == "MAX_TOKENS")
    }
}

/// Captured once per job so changing Settings cannot switch a local request to cloud.
struct MeetingNotes: Sendable {
    let local: Bool
    let llm: any TextLLM
    let jobTag: String

    init(defaults: UserDefaults = .standard) throws {
        local = Self.usesLocal(defaults: defaults)
        if local {
            let config = try LocalTextLLM.Configuration(
                endpoint: defaults.string(forKey: "Corder.set.localLLMEndpoint") ?? LocalTextLLM.defaultEndpoint,
                model: defaults.string(forKey: "Corder.set.localLLMModel") ?? "",
                contextTokens: AppSettings.localLLMContextTokens(in: defaults))
            llm = LocalTextLLM(config: config)
            jobTag = "local:\(config.chatURL.absoluteString):\(config.model):\(config.contextTokens)"
        } else {
            llm = GeminiTextLLM(channel: .summary)
            jobTag = "cloud"
        }
    }

    static func usesLocal(defaults: UserDefaults = .standard) -> Bool {
        AppSettings.localOnly(in: defaults) || defaults.string(forKey: "Corder.set.summaryProvider") == "local"
    }

    static func languageInstruction(_ languageISO: String?) -> String {
        let lang = languageISO?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if lang.isEmpty || lang == "auto" {
            return "Write directly in the meeting transcript's language, including all headings and titles. Never create an English intermediate summary or translate the meeting into English."
        }
        let name = Locale(identifier: "en").localizedString(forLanguageCode: lang) ?? lang
        return "Write directly in \(name) (\(lang)), the meeting language, including all headings and titles. Never create an English intermediate summary."
    }

    func summarize(_ transcript: String, languageISO: String?) async throws -> String? {
        try await GeminiSummarizer.generate(transcript: transcript, languageISO: languageISO, llm: llm)
    }

    func chapters(_ timedLines: [(startMs: Int64, text: String)], durationMs: Int64?, languageISO: String?) async throws -> [GeminiChapters.Chapter]? {
        let backend: any TextLLM = local ? llm : GeminiTextLLM(channel: .chapters)
        return try await GeminiChapters.generate(timedLines: timedLines, durationMs: durationMs, languageISO: languageISO, llm: backend)
    }
}
