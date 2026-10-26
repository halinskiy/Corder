import XCTest
@testable import Corder

final class CloudPrivacyTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "CorderPrivacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testCleanDefaultsAndStoredOptOuts() {
        withDefaults { defaults in
            XCTAssertTrue(AppSettings.telemetryEnabled(in: defaults))
            XCTAssertTrue(AppSettings.autoTitle(in: defaults))
            XCTAssertTrue(AppSettings.syncTranscripts(in: defaults))
            XCTAssertFalse(AppSettings.localOnly(in: defaults))
            defaults.set(false, forKey: "Corder.set.telemetry")
            defaults.set(false, forKey: "Corder.set.autoTitle")
            defaults.set(false, forKey: "Corder.set.syncTranscripts")
            XCTAssertFalse(AppSettings.telemetryEnabled(in: defaults))
            XCTAssertFalse(AppSettings.autoTitle(in: defaults))
            XCTAssertFalse(AppSettings.syncTranscripts(in: defaults))
        }
    }

    func testLocalOnlyAllowsExactlyModelDownloadsAndUpdates() {
        withDefaults { defaults in
            for channel in NetworkPolicy.Channel.allCases {
                XCTAssertTrue(NetworkPolicy.allows(channel, defaults: defaults), "\(channel)")
            }
            defaults.set(true, forKey: "Corder.set.localOnly")
            for channel in NetworkPolicy.Channel.allCases {
                XCTAssertEqual(NetworkPolicy.allows(channel, defaults: defaults),
                               channel == .modelDownload || channel == .updates, "\(channel)")
            }
            XCTAssertEqual(NetworkPolicy.transcriptionProvider(.groq, defaults: defaults), .whisperLocal)
            XCTAssertEqual(NetworkPolicy.transcriptionProvider(.gemini, defaults: defaults), .whisperLocal)
        }
    }

    func testSyncOptOutBlocksContentAndShareButKeepsAccountAndErrors() {
        withDefaults { defaults in
            defaults.set(false, forKey: "Corder.set.syncTranscripts")
            for channel in [NetworkPolicy.Channel.transcriptSync, .share, .cloudMedia] {
                XCTAssertFalse(NetworkPolicy.allows(channel, defaults: defaults))
            }
            for channel in [NetworkPolicy.Channel.account, .lastError, .title, .summary, .cloudTranscription] {
                XCTAssertTrue(NetworkPolicy.allows(channel, defaults: defaults))
            }
            defaults.set(false, forKey: "Corder.set.autoTitle")
            XCTAssertFalse(NetworkPolicy.allows(.title, defaults: defaults))
        }
    }

    func testAuxiliaryLoadCancelsBeforeRecoveryCanContinue() async throws {
        let name = "CorderAuxiliaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let started = expectation(description: "auxiliary model operation started")
        let operation = Task {
            try await NetworkPolicy.withAuxiliaryModels(defaults: defaults) {
                started.fulfill()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { /* dependency may attempt recovery after cancellation */ }
                try Task.checkCancellation()
                return true
            }
        }
        await fulfillment(of: [started], timeout: 2)
        NetworkPolicy.cancelAuxiliaryOperations()
        do {
            _ = try await operation.value
            XCTFail("a cancelled model operation must not continue its recovery")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
    }

    func testCachedDiarizerMissingFilesFailLocally() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try CachedDiarizerModels.load(from: root))
    }

    func testSettingsPatchMissingFieldsStayAbsent() throws {
        let empty = try JSONDecoder().decode(DTO.Settings.self, from: Data("{}".utf8))
        XCTAssertNil(empty.sync_transcripts)
        XCTAssertNil(empty.local_only)
        XCTAssertNil(empty.auto_title)
        let patch = try JSONDecoder().decode(DTO.Settings.self, from: Data(#"{"sync_transcripts":false,"auto_title":false,"local_only":true}"#.utf8))
        XCTAssertEqual(patch.sync_transcripts, false)
        XCTAssertEqual(patch.auto_title, false)
        XCTAssertEqual(patch.local_only, true)
    }

    func testTitleExcerptUsesThreeBoundedWholeLineWindows() {
        let lines = (0..<200).map { "speaker \($0): " + String(repeating: "я", count: 70) }
        let text = lines.joined(separator: "\n")
        let sample = TranscriptSampling.titleExcerpt(text)
        let parts = sample.components(separatedBy: "\n[...]\n")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts[0].hasPrefix(lines[0]))
        XCTAssertTrue(parts[2].hasSuffix(lines[199]))
        XCTAssertTrue(parts[1].contains(lines[100]))
        for part in parts {
            XCTAssertLessThanOrEqual(part.count, 900)
            for line in part.components(separatedBy: "\n") { XCTAssertTrue(lines.contains(line)) }
        }
        XCTAssertEqual(TranscriptSampling.titleExcerpt("short\ntranscript"), "short\ntranscript")
        XCTAssertEqual(TranscriptSampling.titleExcerpt(""), "")
        XCTAssertLessThanOrEqual(TranscriptSampling.titleExcerpt(String(repeating: "x", count: 10_000)).count, 2714)
    }

    func testTelemetryPayloadExactAllowlist() throws {
        let suite = "CorderTelemetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var meeting = Meeting(id: "private-meeting", startedAt: 1, videoPath: "/private/video.mov",
                              audioPath: "/private/audio.wav", status: .ready)
        meeting.title = "private-title"
        meeting.summary = "private-summary"
        meeting.durationMs = 1000
        meeting.transcriptionClass = "local"
        let payload = TelemetryPayload.make(id: "pseudonym", appVersion: "test", macOS: "test",
            macModel: "test", ramGB: 8, tier: "free", meetings: [meeting],
            counters: TelemetryService.drainCounters(in: defaults))
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["anonymous_id", "app_version", "macos_version", "mac_model", "ram_gb", "tier", "events"]))
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["meetings_ready"] as? Int, 1)
        XCTAssertEqual(events[0]["transcribed_local"] as? Int, 1)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-"))
        XCTAssertEqual(Set(events[0].keys), Set([
            "window_hours", "meetings_total", "meetings_ready", "meetings_failed", "meetings_transcribing",
            "transcribed_advanced", "transcribed_local", "total_duration_ms", "reliab_recordings",
            "reliab_btRecordings", "reliab_farEndLost", "reliab_btFarEndLost", "reliab_tapRebuilds"]))
    }
}
