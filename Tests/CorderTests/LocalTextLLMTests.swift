import XCTest
import Swifter
import GRDB
@testable import Corder

final class LocalTextLLMTests: XCTestCase {
    func testOllamaRequestCarriesContextModelAndLanguage() throws {
        let config = try LocalTextLLM.Configuration(endpoint: "http://127.0.0.1:11434/api/chat", model: "qwen3:14b", contextTokens: 8192)
        let request = try LocalTextLLM(config: config).request(model: config.model, system: MeetingNotes.languageInstruction("ru"), transcript: "Решили выпустить в пятницу", maxOutputTokens: 2000, json: false)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(request.url?.path, "/api/chat")
        XCTAssertEqual(body["model"] as? String, "qwen3:14b")
        XCTAssertEqual((body["options"] as? [String: Any])?["num_ctx"] as? Int, 8192)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertTrue(String(data: request.httpBody!, encoding: .utf8)!.contains("ru"))
    }

    func testOpenAIRequestAndResponse() throws {
        let config = try LocalTextLLM.Configuration(endpoint: "http://localhost:1234/v1/", model: "qwen", contextTokens: 8192)
        let request = try LocalTextLLM(config: config).request(model: "qwen", system: "Russian", transcript: "Текст", maxOutputTokens: 2000, json: true)
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "qwen")
        XCTAssertEqual(body["max_tokens"] as? Int, 2000)
        let reply = try LocalTextLLM.parse(Data(####"{"choices":[{"message":{"content":"### Решения\n- Выпустить"},"finish_reason":"stop"}]}"####.utf8), ollama: false, contextTokens: 8192)
        XCTAssertEqual(reply.text, "### Решения\n- Выпустить")
        XCTAssertFalse(reply.truncated)
    }

    func testOllamaParsingRejectsContextSaturation() throws {
        let data = Data(####"{"message":{"content":"Готово"},"prompt_eval_count":120,"done_reason":"stop"}"####.utf8)
        XCTAssertEqual(try LocalTextLLM.parse(data, ollama: true, contextTokens: 8192).text, "Готово")
        let saturated = Data(####"{"message":{"content":"Неполный итог"},"prompt_eval_count":8192}"####.utf8)
        XCTAssertThrowsError(try LocalTextLLM.parse(saturated, ollama: true, contextTokens: 8192)) {
            XCTAssertEqual($0 as? LocalTextLLM.Failure, .contextTruncated)
        }
    }

    func testMalformedEmptyAndLengthResponses() throws {
        for raw in ["{}", ####"{"message":{"content":""}}"####, ####"{"error":"bad model"}"####] {
            XCTAssertThrowsError(try LocalTextLLM.parse(Data(raw.utf8), ollama: true, contextTokens: 8192))
        }
        let reply = try LocalTextLLM.parse(Data(####"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"####.utf8), ollama: false, contextTokens: 8192)
        XCTAssertTrue(reply.truncated)
    }

    func testCyrillicBudgetReservesSystemOutputAndCoversEnding() throws {
        let system = String(repeating: "Инструкция ", count: 50)
        let transcript = (0..<4000).map { "Строка \($0): обсудили выпуск продукта в пятницу." }.joined(separator: "\n")
        let sampled = try LocalTextLLM.sample(transcript, system: system, contextTokens: 8192, maxOutputTokens: 2000)
        XCTAssertLessThanOrEqual(LocalTextLLM.estimatedTokens(system + "\nTranscript:\n" + sampled) + 2000 + 256, 8192)
        XCTAssertTrue(sampled.contains("Строка 0:"))
        XCTAssertTrue(sampled.contains("Строка 3999:"))
        XCTAssertTrue(sampled.contains("[…]"))
        XCTAssertEqual(LocalTextLLM.estimatedTokens("абвгд"), 2)
        XCTAssertThrowsError(try LocalTextLLM.sample(transcript, system: system, contextTokens: 1024, maxOutputTokens: 2000))
    }

    func testLoopbackOnlyAndNativeOllamaNormalization() throws {
        for endpoint in ["https://example.com/v1", "http://127.0.0.1.evil.com/v1", "file:///tmp/model", "http://user:pass@localhost/v1", "http://localhost/v1?key=secret"] {
            XCTAssertThrowsError(try LocalTextLLM.Configuration(endpoint: endpoint))
        }
        XCTAssertEqual(try LocalTextLLM.Configuration(endpoint: "http://localhost:11434").chatURL.path, "/api/chat")
        XCTAssertEqual(try LocalTextLLM.Configuration(endpoint: "http://localhost:11434/v1").chatURL.path, "/api/chat")
        XCTAssertEqual(try LocalTextLLM.Configuration(endpoint: "http://127.0.0.1:8080/v1").chatURL.path, "/v1/chat/completions")
    }

    func testLocalOnlyOverridesCloudWithoutAccountGate() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertFalse(MeetingNotes.usesLocal(defaults: defaults))
        defaults.set(true, forKey: "Corder.set.localOnly")
        XCTAssertTrue(MeetingNotes.usesLocal(defaults: defaults))
        defaults.set(false, forKey: "Corder.set.localOnly")
        // The Summaries picker is gone: a stored "local" no longer routes locally.
        defaults.set("local", forKey: "Corder.set.summaryProvider")
        XCTAssertFalse(MeetingNotes.usesLocal(defaults: defaults))
    }

    func testCloudDefaultDoesNotValidateOrUseLocalModelSettings() throws {
        let name = "CloudNotesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("invalid local endpoint", forKey: "Corder.set.localLLMEndpoint")
        defaults.set("unavailable-model", forKey: "Corder.set.localLLMModel")
        let notes = try MeetingNotes(defaults: defaults)
        XCTAssertFalse(notes.local)
        XCTAssertTrue(notes.llm is GeminiTextLLM)
        XCTAssertEqual(notes.jobTag, "cloud")
    }

    func testEvenSampleHasStrictCharacterBudget() {
        let text = (0..<500).map { "\($0) " + String(repeating: "я", count: 30) }.joined(separator: "\n")
        let sampled = TranscriptSampling.evenSample(text, budget: 400, windows: 6)
        XCTAssertLessThanOrEqual(sampled.count, 400)
        XCTAssertTrue(sampled.contains("499 "))
    }
    private func probeServer() throws -> (HttpServer, String) {
        let server = HttpServer()
        server.listenAddressIPv4 = "127.0.0.1"
        try server.start(0, forceIPv4: true)
        return (server, "http://127.0.0.1:\(try server.port())")
    }

    func testModelDiscoveryPrefersLoadedTextModel() async throws {
        let (server, base) = try probeServer()
        defer { server.stop() }
        server.get["/v1/models"] = { _ in .ok(.json(["data": [
            ["id": "text-embedding", "state": "loaded"],
            ["id": "qwen-unloaded", "state": "not-loaded"],
            ["id": "qwen-loaded", "state": "loaded"]
        ]])) }
        let client = LocalTextLLM(config: try .init(endpoint: base + "/v1"))
        let model = try await client.discoverModel()
        XCTAssertEqual(model, "qwen-loaded")
    }

    func testNativeOllamaDiscoversRunningModelAndUsesChat() async throws {
        let (server, base) = try probeServer()
        defer { server.stop() }
        server.get["/api/ps"] = { _ in .ok(.json(["models": [["name": "qwen3:14b"]]])) }
        server.post["/api/chat"] = { request in
            let body = try! JSONSerialization.jsonObject(with: Data(request.body)) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "qwen3:14b")
            XCTAssertEqual((body["options"] as? [String: Any])?["num_ctx"] as? Int, 16384)
            XCTAssertNil(request.headers["authorization"])
            return .ok(.json(["message": ["content": "### Решения\n- Выпустить в пятницу"], "prompt_eval_count": 100]))
        }
        let client = LocalTextLLM(config: try .init(endpoint: base + "/api/chat"))
        let reply = try await client.complete(system: MeetingNotes.languageInstruction("ru"), transcript: "Выпускаем в пятницу", maxOutputTokens: 2000, json: false)
        XCTAssertTrue(Routes.isStructuredMarkdown(try XCTUnwrap(reply?.text)))
    }

    func testExplicitModelSkipsDiscoveryAndLocalHTTP403IsAnError() async throws {
        let (server, base) = try probeServer()
        defer { server.stop() }
        server.get["/v1/models"] = { _ in XCTFail("Explicit model should not require discovery"); return .notFound }
        server.post["/v1/chat/completions"] = { _ in .forbidden }
        let client = LocalTextLLM(config: try .init(endpoint: base + "/v1", model: "qwen"))
        do {
            _ = try await client.complete(system: "Russian", transcript: "Текст", maxOutputTokens: 2000, json: false)
            XCTFail("Expected a local error")
        } catch {
            XCTAssertEqual(error as? LocalTextLLM.Failure, .requestFailed)
            XCTAssertFalse(error is PaidFeatureError)
        }
    }

    func testRedirectsAreRejectedWithoutFollowing() async throws {
        let (server, base) = try probeServer()
        defer { server.stop() }
        server.get["/v1/models"] = { _ in .movedPermanently(base + "/redirected") }
        server.get["/redirected"] = { _ in XCTFail("Must not follow a local server redirect"); return .ok(.json(["data": [["id": "qwen"]]])) }
        do {
            _ = try await LocalTextLLM(config: .init(endpoint: base + "/v1")).discoverModel()
            XCTFail("Expected redirect rejection")
        } catch { XCTAssertEqual(error as? LocalTextLLM.Failure, .requestFailed) }
    }

    func testNoLoadedModelAndUnavailableServer() async throws {
        let (server, base) = try probeServer()
        server.get["/v1/models"] = { _ in .ok(.json(["data": []])) }
        let client = LocalTextLLM(config: try .init(endpoint: base + "/v1"))
        do { _ = try await client.discoverModel(); XCTFail("Expected no model") }
        catch { XCTAssertEqual(error as? LocalTextLLM.Failure, .noModel) }
        server.stop()
        do { _ = try await client.discoverModel(); XCTFail("Expected unavailable server") }
        catch { XCTAssertEqual(error as? LocalTextLLM.Failure, .unavailable) }
    }

    func testChapterIndicesAndLanguageSurviveLocalSampling() async throws {
        let (server, base) = try probeServer()
        defer { server.stop() }
        server.post["/v1/chat/completions"] = { request in
            let body = try! JSONSerialization.jsonObject(with: Data(request.body)) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            XCTAssertTrue(messages[0]["content"]!.contains("Russian (ru)"))
            XCTAssertTrue(messages[1]["content"]!.contains("0 [00:00]"))
            XCTAssertTrue(messages[1]["content"]!.contains("29 [29:00]"))
            XCTAssertTrue(messages[1]["content"]!.contains("[…]"))
            let chapters = "{\"chapters\":[{\"start_index\":0,\"title\":\"Начало\"},{\"start_index\":29,\"title\":\"Решение по выпуску\"}]}"
            return .ok(.json(["choices": [["message": ["content": chapters], "finish_reason": "stop"]]]))
        }
        let client = LocalTextLLM(config: try .init(endpoint: base + "/v1", model: "qwen", contextTokens: 8192))
        let lines = (0..<30).map { (startMs: Int64($0 * 60000), text: String(repeating: "Выпуск продукта в пятницу. ", count: 200)) }
        let chapters = try await GeminiChapters.generate(timedLines: lines, durationMs: 1800000, languageISO: "ru", llm: client)
        XCTAssertEqual(chapters?.map(\.startMs), [0, 1740000])
        let encoded = try JSONEncoder().encode(XCTUnwrap(chapters))
        XCTAssertTrue(String(data: encoded, encoding: .utf8)!.contains("start_ms"))
    }

    func testDetectedLanguagePersistsWithoutClobberingMeeting() throws {
        let db = try DatabaseQueue()
        try Migrations.register().migrate(db)
        let repo = MeetingRepository(dbq: db)
        var meeting = Meeting.fixture(id: UUID().uuidString)
        meeting.title = "Approved title"
        try repo.insertMeeting(meeting)
        try repo.setDetectedMeetingLanguage(meetingId: meeting.id, language: "ru")
        let saved = try repo.meeting(id: meeting.id)
        XCTAssertEqual(saved?.detectedMeetingLang, "ru")
        XCTAssertEqual(saved?.title, "Approved title")
    }

    func testV25UpgradePreservesExistingMeetingAndTranscript() throws {
        let dbq = try DatabaseQueue()
        let migrator = Migrations.register()
        try migrator.migrate(dbq, upTo: "v24_source")
        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO meetings (id, started_at, video_path, audio_path, status, title, summary, chapters, gemini_raw_turns, audio_hash, dir_name)
                VALUES ('old', 123, '/video.mov', '/mic.wav', 'ready', 'Title', '### Decisions\n- Ship', '[]', 'cached turns', 'hash', 'folder');
                INSERT INTO speakers (id, meeting_id, label, color_hex) VALUES ('speaker', 'old', 'user', '#000000');
                INSERT INTO segments (meeting_id, speaker_id, start_ms, end_ms, text) VALUES ('old', 'speaker', 0, 1000, 'Original transcript');
                """)
        }
        let before = try dbq.read { try Row.fetchOne($0, sql: "SELECT * FROM meetings WHERE id = 'old'")! }
        try migrator.migrate(dbq)
        try migrator.migrate(dbq)
        try dbq.read { db in
            let after = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM meetings WHERE id = 'old'"))
            for column in before.columnNames {
                XCTAssertEqual(before[column] as DatabaseValue, after[column] as DatabaseValue, column)
            }
            XCTAssertTrue((after["detected_meeting_lang"] as DatabaseValue).isNull)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT text FROM segments"), "Original transcript")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM segments_fts WHERE segments_fts MATCH 'Original'"), 1)
        }
    }

    func testOptionalSettingsFieldsDoNotResetExistingValues() throws {
        let empty = try JSONDecoder().decode(DTO.Settings.self, from: Data("{}".utf8))
        XCTAssertNil(empty.summary_provider)
        XCTAssertNil(empty.local_llm_endpoint)
        XCTAssertNil(empty.local_llm_model)
        XCTAssertNil(empty.local_llm_context_tokens)
    }

    func testJITModelListUsesLoadedLMStudioInstance() async throws {
        let (server, base) = try probeServer()
        defer { server.stop() }
        server.get["/v1/models"] = { _ in .ok(.json(["data": [["id": "huge-unloaded"], ["id": "loaded-qwen"]]])) }
        server.get["/api/v1/models"] = { _ in .ok(.json(["models": [
            ["key": "huge-unloaded", "type": "llm", "loaded_instances": []] as [String: Any],
            ["key": "qwen", "type": "llm", "loaded_instances": [["id": "loaded-qwen"]]] as [String: Any]
        ]])) }
        let model = try await LocalTextLLM(config: .init(endpoint: base + "/v1")).discoverModel()
        XCTAssertEqual(model, "loaded-qwen")
    }

    func testMissingOllamaTokenCountCannotSilentlyHideTruncation() {
        XCTAssertThrowsError(try LocalTextLLM.parse(Data("{\"message\":{\"content\":\"Result\"}}".utf8), ollama: true, contextTokens: 16384))
    }

    func testSummaryUsesMeetingLanguageAndStructuredMarkdownInOneRequest() async throws {
        let (server, base) = try probeServer()
        defer { server.stop() }
        server.post["/v1/chat/completions"] = { request in
            let body = try! JSONSerialization.jsonObject(with: Data(request.body)) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            XCTAssertTrue(messages[0]["content"]!.hasPrefix("Write directly in Russian (ru)"))
            XCTAssertTrue(messages[0]["content"]!.contains("Never create an English intermediate summary"))
            XCTAssertEqual(messages[1]["content"], "Transcript:\n\nРешили выпустить в пятницу")
            return .ok(.json(["choices": [["message": ["content": "### Решения\n- Выпустить в **пятницу**"], "finish_reason": "stop"]]]))
        }
        let client = LocalTextLLM(config: try .init(endpoint: base + "/v1", model: "qwen"))
        let summary = try await GeminiSummarizer.generate(transcript: "Решили выпустить в пятницу", languageISO: "ru", llm: client)
        XCTAssertEqual(summary, "### Решения\n- Выпустить в **пятницу**")
        XCTAssertTrue(Routes.isStructuredMarkdown(try XCTUnwrap(summary)))
    }

    func testGuestLocalRoutingAndLocalOnlySnapshotNeverUseCloud() async throws {
        let (server, base) = try probeServer()
        defer { server.stop() }
        server.post["/v1/chat/completions"] = { request in
            XCTAssertNil(request.headers["authorization"])
            let body = try! JSONSerialization.jsonObject(with: Data(request.body)) as! [String: Any]
            let output = body["response_format"] == nil
                ? "### Решения\n- Выпустить"
                : "{\"chapters\":[{\"start_index\":0,\"title\":\"Решение о выпуске\"}]}"
            return .ok(.json(["choices": [["message": ["content": output], "finish_reason": "stop"]]]))
        }
        let name = "LocalNotesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(base + "/v1", forKey: "Corder.set.localLLMEndpoint")
        defaults.set("qwen", forKey: "Corder.set.localLLMModel")
        for localOnly in [true] {
            defaults.set(localOnly, forKey: "Corder.set.localOnly")
            defaults.set("cloud", forKey: "Corder.set.summaryProvider")
            let notes = try MeetingNotes(defaults: defaults)
            XCTAssertTrue(notes.local)
            XCTAssertTrue(notes.llm is LocalTextLLM)
            // Changing preferences after capture must not change this job.
            defaults.set(false, forKey: "Corder.set.localOnly")
            defaults.set("cloud", forKey: "Corder.set.summaryProvider")
            let summary = try await notes.summarize("Выпускаем", languageISO: "ru")
            XCTAssertEqual(summary, "### Решения\n- Выпустить")
            let chapters = try await notes.chapters([(startMs: 0, text: "Выпускаем")], durationMs: 60000, languageISO: "ru")
            XCTAssertEqual(chapters?.first?.startMs, 0)
        }
    }

}
