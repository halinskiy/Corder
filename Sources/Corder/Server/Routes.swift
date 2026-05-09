import Foundation
import GRDB
import Swifter

enum Routes {
    static func register(server: HttpServer, repo: MeetingRepository) {
        server.get["/"] = { _ in serveIndex() }
        server.get["/index.html"] = { _ in serveIndex() }
        server.get["/assets/:path"] = { req in serveAsset(path: req.params[":path"] ?? "") }

        server.get["/api/meetings"] = { _ in listMeetings(repo: repo) }
        server.get["/api/meetings/:id"] = { req in
            meetingDetail(id: req.params[":id"] ?? "", repo: repo)
        }
        server.get["/api/meetings/:id/transcript.txt"] = { req in
            transcriptText(id: req.params[":id"] ?? "", repo: repo)
        }
        server.get["/api/meetings/:id/video"] = { req in
            serveMedia(id: req.params[":id"] ?? "", kind: .video, repo: repo, headers: req.headers)
        }
        server.get["/api/meetings/:id/audio"] = { req in
            serveMedia(id: req.params[":id"] ?? "", kind: .audio, repo: repo, headers: req.headers)
        }
        server.post["/api/meetings/:id/speakers/:sid/rename"] = { req in
            renameSpeaker(req: req, repo: repo)
        }
        server.post["/api/meetings/:id/retranscribe"] = { req in
            retranscribe(id: req.params[":id"] ?? "", repo: repo)
        }
        server.post["/api/meetings/:id/cancel-transcription"] = { req in
            cancelTranscription(id: req.params[":id"] ?? "")
        }
        server.post["/api/meetings/:id/expected-speakers"] = { req in
            setExpectedSpeakers(id: req.params[":id"] ?? "", req: req, repo: repo)
        }
        server.get["/api/meetings/:id/last-error"] = { req in
            lastError(id: req.params[":id"] ?? "")
        }
        server.get["/api/recording/state"] = { _ in recordingState() }
        server.post["/api/recording/stop"] = { _ in stopRecordingNow() }
        server.get["/api/settings"] = { _ in settingsGet() }
        server.post["/api/settings"] = { req in settingsSet(req: req) }
        server.delete["/api/meetings/:id"] = { req in
            deleteMeeting(id: req.params[":id"] ?? "", repo: repo)
        }
        server.get["/api/archive"] = { _ in listArchived(repo: repo) }
        server.post["/api/meetings/:id/archive"] = { req in
            archive(id: req.params[":id"] ?? "", repo: repo)
        }
        server.post["/api/meetings/:id/restore"] = { req in
            restore(id: req.params[":id"] ?? "", repo: repo)
        }
        server.get["/api/search"] = { req in
            let q = req.queryParams.first(where: { $0.0 == "q" })?.1 ?? ""
            return search(query: q, repo: repo)
        }
    }

    // MARK: static

    private static func serveIndex() -> HttpResponse {
        guard let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "web"),
              let data = try? Data(contentsOf: url) else {
            return .notFound
        }
        return .raw(200, "OK", ["Content-Type": "text/html; charset=utf-8"]) { writer in
            try writer.write(data)
        }
    }

    private static func serveAsset(path: String) -> HttpResponse {
        let webRoot = Bundle.module.bundleURL.appendingPathComponent("web", isDirectory: true)
        let target = webRoot.appendingPathComponent("assets").appendingPathComponent(path)
        guard let data = try? Data(contentsOf: target) else { return .notFound }
        let mime = mimeType(for: target.pathExtension)
        return .raw(200, "OK", ["Content-Type": mime]) { try $0.write(data) }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    // MARK: api

    private static func listMeetings(repo: MeetingRepository) -> HttpResponse {
        do {
            let meetings = try repo.listMeetings()
            let summaries: [DTO.MeetingSummary] = try meetings.map { m in
                let segs = try repo.segments(forMeeting: m.id)
                let speakerIds = Set(segs.map { $0.speakerId })
                let speakers = try repo.speakers(forMeeting: m.id)
                // Join custom_name (when set) or label, only for speakers who
                // actually spoke. Used as a haystack for the sidebar search.
                let activeNames: [String] = speakers
                    .filter { speakerIds.contains($0.id) }
                    .map { ($0.customName?.trimmingCharacters(in: .whitespaces).isEmpty == false)
                        ? $0.customName!
                        : $0.label }
                return DTO.MeetingSummary(
                    id: m.id, started_at: m.startedAt, ended_at: m.endedAt,
                    duration_ms: m.durationMs, status: m.status.rawValue,
                    preview: segs.first?.text,
                    speaker_count: speakerIds.count,
                    speaker_names: activeNames.isEmpty ? nil : activeNames.joined(separator: " · ")
                )
            }
            return jsonResponse(summaries)
        } catch {
            return .internalServerError
        }
    }

    private static func meetingDetail(id: String, repo: MeetingRepository) -> HttpResponse {
        do {
            guard let m = try repo.meeting(id: id) else { return .notFound }
            let speakers = try repo.speakers(forMeeting: id)
            let segments = try repo.segments(forMeeting: id)
            let dto = DTO.MeetingDetail(
                id: m.id, started_at: m.startedAt, duration_ms: m.durationMs,
                status: m.status.rawValue,
                speakers: speakers.map {
                    DTO.SpeakerDTO(id: $0.id, label: $0.label, custom_name: $0.customName, color_hex: $0.colorHex)
                },
                segments: segments.map {
                    DTO.SegmentDTO(id: $0.id ?? 0, speaker_id: $0.speakerId,
                                   start_ms: $0.startMs, end_ms: $0.endMs, text: $0.text,
                                   text_boost: $0.textBoost)
                },
                expected_other_speakers: m.expectedOtherSpeakers
            )
            return jsonResponse(dto)
        } catch {
            return .internalServerError
        }
    }

    private static func transcriptText(id: String, repo: MeetingRepository) -> HttpResponse {
        do {
            let segments = try repo.segments(forMeeting: id)
            let speakers = try repo.speakers(forMeeting: id)
            let text = TranscriptFormatter.clipboardText(segments: segments, speakers: speakers)
            return .raw(200, "OK", ["Content-Type": "text/plain; charset=utf-8"]) {
                try $0.write([UInt8](text.utf8))
            }
        } catch {
            return .internalServerError
        }
    }

    private static func recordingState() -> HttpResponse {
        switch RecordingStateSnapshot.read() {
        case .idle:
            return jsonResponse(["active": false] as [String: Any])
        case .recording(let meetingId, let startedAt):
            return jsonResponse([
                "active": true,
                "meeting_id": meetingId,
                "started_at_ms": Int64(startedAt.timeIntervalSince1970 * 1000)
            ] as [String: Any])
        case .stopping:
            return jsonResponse(["active": true, "stopping": true] as [String: Any])
        }
    }

    private static func stopRecordingNow() -> HttpResponse {
        Task { @MainActor in
            await RecordingController.shared.stopRecording()
        }
        return .ok(.text("stopping"))
    }

    private static func settingsGet() -> HttpResponse {
        return jsonResponse(DTO.Settings(
            boost_mode: BoostMode.isEnabled,
            language: AppLanguage.current
        ))
    }

    private static func settingsSet(req: HttpRequest) -> HttpResponse {
        do {
            let body = Data(req.body)
            let parsed = try JSONDecoder().decode(DTO.Settings.self, from: body)
            UserDefaults.standard.set(parsed.boost_mode, forKey: BoostMode.key)
            if let lang = parsed.language, lang == "ru" || lang == "en" {
                UserDefaults.standard.set(lang, forKey: AppLanguage.key)
                Task { @MainActor in
                    AppContext.shared.language = lang
                }
            }
            FileLogger.log("settings: boost_mode=\(parsed.boost_mode) language=\(parsed.language ?? "nil")")
            return jsonResponse(DTO.Settings(
                boost_mode: parsed.boost_mode,
                language: AppLanguage.current
            ))
        } catch {
            return .badRequest(.text("\(error)"))
        }
    }

    private static func retranscribe(id: String, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        FileLogger.log("retranscribe: queued for \(id)")
        // Flip status + clear old segments synchronously so the very next
        // GET /api/meetings/:id from the UI returns `transcribing` with an
        // empty segment list — letting the TranscribingBanner appear
        // instantly instead of the "Empty transcript" placeholder.
        if var m = try? repo.meeting(id: id) {
            m.status = .transcribing
            try? repo.updateMeeting(m)
        }
        try? repo.clearTranscript(meetingId: id)
        TranscriptionErrors.clear(meetingId: id)
        Task { @MainActor in
            TranscriptionPipeline.shared.enqueue(meetingId: id)
        }
        return .ok(.text("queued"))
    }

    private static func cancelTranscription(id: String) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        FileLogger.log("cancelTranscription: \(id)")
        Task { @MainActor in
            TranscriptionPipeline.shared.cancel(meetingId: id)
        }
        return .ok(.text("cancelled"))
    }

    private static func lastError(id: String) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        let payload: [String: Any] = ["error": TranscriptionErrors.read(meetingId: id) as Any]
        return jsonResponse(payload)
    }

    private static func setExpectedSpeakers(id: String, req: HttpRequest, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        guard let body = try? JSONDecoder().decode(DTO.ExpectedSpeakersRequest.self, from: Data(req.body)) else {
            return .badRequest(.text("bad json"))
        }
        do {
            guard var m = try repo.meeting(id: id) else { return .notFound }
            m.expectedOtherSpeakers = body.count
            try repo.updateMeeting(m)
            return .ok(.text("ok"))
        } catch {
            return .internalServerError
        }
    }

    private static func deleteMeeting(id: String, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        do {
            // Best-effort cleanup of cloud archive (fire-and-forget).
            if let m = try? repo.meeting(id: id) {
                if let vp = m.dropboxVideoPath {
                    Task.detached { await DropboxService.shared.deleteFile(remotePath: vp) }
                }
                if let ap = m.dropboxAudioPath {
                    Task.detached { await DropboxService.shared.deleteFile(remotePath: ap) }
                }
            }
            // Best-effort cleanup of files on disk.
            let dir = AppPaths.recordingDir(for: id)
            try? FileManager.default.removeItem(at: dir)
            try repo.deleteMeeting(id: id)
            return .ok(.text("ok"))
        } catch {
            return .internalServerError
        }
    }

    /// Soft-archive: stamps `archived_at` so the meeting drops out of
    /// the main library and shows up in the archive panel. Audio stays
    /// on disk / Dropbox until the user either restores or wipes it,
    /// or until the 7-day grace period elapses (see launch cleanup).
    private static func archive(id: String, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try repo.setArchived(meetingId: id, archivedAt: now)
            return .ok(.text("ok"))
        } catch {
            return .internalServerError
        }
    }

    private static func restore(id: String, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        do {
            try repo.setArchived(meetingId: id, archivedAt: nil)
            return .ok(.text("ok"))
        } catch {
            return .internalServerError
        }
    }

    private static func listArchived(repo: MeetingRepository) -> HttpResponse {
        do {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let retentionMs: Int64 = 7 * 24 * 60 * 60 * 1000  // 7 days
            let items = try repo.listArchived().map { m -> [String: Any] in
                let archivedAt = m.archivedAt ?? now
                let purgeAt = archivedAt + retentionMs
                return [
                    "id": m.id,
                    "started_at": m.startedAt,
                    "duration_ms": m.durationMs as Any,
                    "archived_at": archivedAt,
                    "purge_at": purgeAt
                ]
            }
            return jsonResponse(["items": items])
        } catch {
            return .internalServerError
        }
    }

    private static func renameSpeaker(req: HttpRequest, repo: MeetingRepository) -> HttpResponse {
        let sid = req.params[":sid"] ?? ""
        guard !sid.isEmpty else { return .badRequest(.text("missing speaker id")) }
        do {
            let body = Data(req.body)
            let parsed = try JSONDecoder().decode(DTO.RenameRequest.self, from: body)
            try repo.renameSpeaker(speakerId: sid, customName: parsed.name)
            return .ok(.text("ok"))
        } catch {
            return .badRequest(.text("\(error)"))
        }
    }

    private static func search(query: String, repo: MeetingRepository) -> HttpResponse {
        guard !query.isEmpty else { return jsonResponse([DTO.SearchHit]()) }
        do {
            let segs = try repo.searchSegments(query: query)
            let hits = segs.map {
                DTO.SearchHit(meeting_id: $0.meetingId, segment_id: $0.id ?? 0,
                              start_ms: $0.startMs, text: $0.text)
            }
            return jsonResponse(hits)
        } catch {
            return .internalServerError
        }
    }

    // MARK: media (Range)

    private enum MediaKind { case video, audio }

    private static func serveMedia(id: String, kind: MediaKind, repo: MeetingRepository, headers: [String: String]) -> HttpResponse {
        do {
            guard let m = try repo.meeting(id: id) else { return .notFound }
            let dropboxRemote = (kind == .video) ? m.dropboxVideoPath : m.dropboxAudioPath
            let contentType = (kind == .video) ? "video/quicktime" : "audio/wav"

            // Audio resolution order:
            //   1. The DB-stored audioPath (usually mic.wav).
            //   2. The post-mix audio.wav inside the meeting dir — this is
            //      what AudioMixer produces and what Whisper/Gemini consume.
            //      When mic.wav never got written (capture race, sleep mid-
            //      recording, etc.) audioPath points at a missing file but
            //      audio.wav is still there — the user expects play to work.
            // Video has only the canonical videoPath; no fallback.
            var url: URL
            if kind == .video {
                url = URL(fileURLWithPath: m.videoPath)
            } else {
                let direct = URL(fileURLWithPath: m.audioPath)
                if FileManager.default.fileExists(atPath: direct.path) {
                    url = direct
                } else {
                    let mixURL = AppPaths.recordingDir(for: id).appendingPathComponent("audio.wav")
                    url = mixURL
                }
            }

            // Cloud cache miss: file was archived to Dropbox and the local
            // copy got deleted. Pull it back to the canonical local path
            // (one-time blocking download), then continue down the regular
            // local-file branch — including Range support. Subsequent
            // scrubbing requests are served straight from disk without
            // re-blocking a Swifter worker.
            if !FileManager.default.fileExists(atPath: url.path), let remote = dropboxRemote {
                FileLogger.log("serveMedia: cache miss for \(id) (\(kind)), fetching from Dropbox \(remote)")
                guard hydrateDropboxFile(remote: remote, localURL: url) else {
                    return .internalServerError
                }
            }

            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

            // Swifter lower-cases header keys.
            guard let rangeHeader = headers["range"] ?? headers["Range"] else {
                let data = try Data(contentsOf: url)
                return .raw(200, "OK", [
                    "Content-Type": contentType,
                    "Accept-Ranges": "bytes",
                    "Content-Length": "\(size)"
                ]) { try $0.write(data) }
            }

            guard let r = RangeRequest.parse(rangeHeader, fileSize: size) else {
                return .raw(416, "Range Not Satisfiable", [
                    "Content-Range": "bytes */\(size)"
                ]) { _ in }
            }

            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: UInt64(r.start))
            let chunk = handle.readData(ofLength: Int(r.length))
            try? handle.close()

            return .raw(206, "Partial Content", [
                "Content-Type": contentType,
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(r.start)-\(r.end)/\(size)",
                "Content-Length": "\(r.length)"
            ]) { try $0.write(chunk) }
        } catch {
            return .internalServerError
        }
    }

    /// One-time Dropbox → local restore. Used by `serveMedia` when the
    /// canonical local file has been archived and deleted. Blocks the
    /// calling Swifter worker for the duration of the download (which can
    /// be tens of seconds for an hour-long meeting), but only on the very
    /// first request — once the file lands at `localURL` every subsequent
    /// request, including Range scrubs, is served straight from disk
    /// without ever touching this code path again.
    ///
    /// We deliberately don't proxy bytes per-request the way the previous
    /// implementation did: scrubbing produces dozens of Range requests in
    /// a few seconds, each of which would have blocked a worker thread on
    /// its own `URLSession.data` round-trip and hammered Dropbox's
    /// rate limit.
    private static func hydrateDropboxFile(remote: String, localURL: URL) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        Task.detached {
            defer { semaphore.signal() }
            do {
                try await DropboxService.shared.download(remotePath: remote, to: localURL)
                ok = true
            } catch {
                FileLogger.log("hydrateDropboxFile: \(remote) → \(localURL.lastPathComponent) failed: \(error)")
            }
        }
        semaphore.wait()
        return ok
    }

    // MARK: helpers

    private static func jsonResponse<T: Encodable>(_ value: T) -> HttpResponse {
        do {
            let enc = JSONEncoder()
            let data = try enc.encode(value)
            return .raw(200, "OK", ["Content-Type": "application/json; charset=utf-8"]) {
                try $0.write([UInt8](data))
            }
        } catch {
            return .internalServerError
        }
    }

    private static func jsonResponse(_ value: [String: Any]) -> HttpResponse {
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            return .raw(200, "OK", ["Content-Type": "application/json; charset=utf-8"]) {
                try $0.write([UInt8](data))
            }
        } catch {
            return .internalServerError
        }
    }
}
