import Foundation

struct LocalTextLLM: TextLLM {
    static let defaultEndpoint = "http://127.0.0.1:1234/v1"

    enum Failure: String, LocalizedError, Equatable {
        case unavailable = "local_llm_unavailable"
        case invalidEndpoint = "local_llm_invalid_endpoint"
        case noModel = "local_llm_no_model"
        case invalidResponse = "local_llm_invalid_response"
        case contextTruncated = "local_llm_context_truncated"
        case contextTooSmall = "local_llm_context_too_small"
        case requestFailed = "local_llm_request_failed"
        case outputTruncated = "local_llm_output_truncated"
        var errorDescription: String? { rawValue }
    }

    struct Configuration: Sendable {
        let chatURL: URL
        let modelsURL: URL
        let ollama: Bool
        let model: String
        let contextTokens: Int

        init(endpoint: String, model: String = "", contextTokens: Int = 16384) throws {
            guard var parts = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  ["127.0.0.1", "localhost", "[::1]", "::1"].contains(parts.host?.lowercased() ?? ""),
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  (4096...262144).contains(contextTokens) else { throw Failure.invalidEndpoint }
            var path = parts.path
            while path.hasSuffix("/") { path.removeLast() }
            ollama = parts.port == 11434 || path == "/api/chat" || path == "/api"
            if ollama {
                parts.path = "/api/chat"
            } else {
                if path.isEmpty { path = "/v1" }
                parts.path = path.hasSuffix("/chat/completions") ? path : path + "/chat/completions"
            }
            guard let chatURL = parts.url else { throw Failure.invalidEndpoint }
            self.chatURL = chatURL
            parts.path = ollama ? "/api/ps" : String(parts.path.dropLast("/chat/completions".count)) + "/models"
            guard let modelsURL = parts.url else { throw Failure.invalidEndpoint }
            self.modelsURL = modelsURL
            self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            self.contextTokens = contextTokens
        }
    }

    let config: Configuration
    // Avoid app/SDK sessions, credentials, proxies, caches and all redirects.
    // Only literal loopback endpoints are accepted, even outside Local only.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func estimatedTokens(_ text: String) -> Int {
        // Conservative for Cyrillic Qwen transcripts; applies to the prompt too.
        Int(ceil(Double(text.count) / 2.5))
    }

    static func sample(_ transcript: String, system: String, contextTokens: Int, maxOutputTokens: Int) throws -> String {
        let available = contextTokens - maxOutputTokens - estimatedTokens(system + "\nTranscript:\n\n") - 256
        guard available >= 256 else { throw Failure.contextTooSmall }
        let budget = Int(Double(available) * 2.5)
        let sampled = TranscriptSampling.evenSample(transcript, budget: budget, windows: 8)
        if sampled.count < transcript.count {
            FileLogger.log("LocalTextLLM: sampled transcript \(transcript.count) to \(sampled.count) characters for context \(contextTokens)")
        }
        return sampled
    }

    func request(model: String, system: String, transcript: String, maxOutputTokens: Int, json: Bool) throws -> URLRequest {
        let sampled = try Self.sample(transcript, system: system, contextTokens: config.contextTokens, maxOutputTokens: maxOutputTokens)
        var body: [String: Any] = [
            "model": model, "stream": false,
            "messages": [["role": "system", "content": system], ["role": "user", "content": "Transcript:\n\n\(sampled)"]]
        ]
        if config.ollama {
            body["options"] = ["num_ctx": config.contextTokens, "num_predict": maxOutputTokens, "temperature": 0.3] as [String: Any]
            if json { body["format"] = "json" }
        } else {
            body["max_tokens"] = maxOutputTokens
            body["temperature"] = 0.3
            if json { body["response_format"] = ["type": "json_object"] }
        }
        var request = URLRequest(url: config.chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 600
        return request
    }

    private func data(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                FileLogger.log("LocalTextLLM: HTTP \(http.statusCode)")
                throw Failure.requestFailed
            }
            return data
        } catch let failure as Failure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch {
            FileLogger.log("LocalTextLLM: connection failed (\((error as NSError).code))")
            throw Failure.unavailable
        }
    }

    func discoverModel() async throws -> String {
        var request = URLRequest(url: config.modelsURL)
        request.timeoutInterval = 10
        let data = try await data(for: request)
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidResponse }
        let models = (payload[config.ollama ? "models" : "data"] as? [[String: Any]]) ?? []
        var candidates = models.filter { model in
            let id = model[config.ollama ? "name" : "id"] as? String ?? ""
            let type = model["type"] as? String ?? "llm"
            return !id.isEmpty && !id.lowercased().contains("embedding") && type != "embedding"
                && model["state"] as? String != "not-loaded" && model["state"] as? String != "unloaded"
        }
        // LM Studio's JIT /v1/models can include unloaded models. Its optional
        // native inventory identifies loaded instances without loading anything.
        // llama.cpp and older servers can simply return 404 for this probe.
        if !config.ollama, !models.contains(where: { $0["state"] != nil }),
           var nativeURL = URLComponents(url: config.modelsURL, resolvingAgainstBaseURL: false) {
            nativeURL.path = "/api/v1/models"
            if let url = nativeURL.url {
                var probe = URLRequest(url: url)
                probe.timeoutInterval = 2
                if let (nativeData, response) = try? await Self.session.data(for: probe),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let payload = try? JSONSerialization.jsonObject(with: nativeData) as? [String: Any],
                   let inventory = payload["models"] as? [[String: Any]] {
                    let loaded = Set(inventory.filter { $0["type"] as? String == "llm" }.flatMap {
                        ($0["loaded_instances"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                    })
                    candidates = candidates.filter { loaded.contains($0["id"] as? String ?? "") }
                }
            }
        }
        if !config.model.isEmpty {
            guard candidates.contains(where: { ($0[config.ollama ? "name" : "id"] as? String) == config.model }) else { throw Failure.noModel }
            return config.model
        }
        let first = candidates.first(where: { $0["state"] as? String == "loaded" }) ?? candidates.first
        guard let model = first?[config.ollama ? "name" : "id"] as? String else { throw Failure.noModel }
        return model
    }

    static func parse(_ data: Data, ollama: Bool, contextTokens: Int) throws -> TextLLMReply {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any], payload["error"] == nil else { throw Failure.invalidResponse }
        let text: String?
        let truncated: Bool
        if ollama {
            guard let count = payload["prompt_eval_count"] as? Int, count >= 0 else { throw Failure.invalidResponse }
            FileLogger.log("LocalTextLLM: Ollama prompt_eval_count=\(count), num_ctx=\(contextTokens)")
            guard count < contextTokens - 32 else {
                FileLogger.log("LocalTextLLM: WARNING possible input truncation, prompt_eval_count=\(count), num_ctx=\(contextTokens)")
                throw Failure.contextTruncated
            }
            text = (payload["message"] as? [String: Any])?["content"] as? String
            truncated = payload["done_reason"] as? String == "length"
        } else {
            let choice = (payload["choices"] as? [[String: Any]])?.first
            text = (choice?["message"] as? [String: Any])?["content"] as? String
            truncated = choice?["finish_reason"] as? String == "length"
        }
        var cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleaned.hasPrefix("<think>"), let end = cleaned.range(of: "</think>") {
            cleaned = String(cleaned[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.hasPrefix("```"), let firstLine = cleaned.firstIndex(of: "\n"), cleaned.hasSuffix("```") {
            cleaned = String(cleaned[cleaned.index(after: firstLine)..<cleaned.index(cleaned.endIndex, offsetBy: -3)]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !cleaned.isEmpty else { throw Failure.invalidResponse }
        return TextLLMReply(text: cleaned, truncated: truncated)
    }

    func complete(system: String, transcript: String, maxOutputTokens: Int, json: Bool) async throws -> TextLLMReply? {
        let model = config.model.isEmpty ? try await discoverModel() : config.model
        let request = try request(model: model, system: system, transcript: transcript, maxOutputTokens: maxOutputTokens, json: json)
        return try Self.parse(await data(for: request), ollama: config.ollama, contextTokens: config.contextTokens)
    }
}
