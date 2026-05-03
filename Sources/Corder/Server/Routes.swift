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
            retranscribe(id: req.params[":id"] ?? "")
        }
        server.post["/api/meetings/:id/boost"] = { req in
            boostMeeting(id: req.params[":id"] ?? "", repo: repo)
        }
        server.get["/api/recording/state"] = { _ in recordingState() }
        server.post["/api/recording/stop"] = { _ in stopRecordingNow() }
        server.get["/api/settings"] = { _ in settingsGet() }
        server.post["/api/settings"] = { req in settingsSet(req: req) }
        server.delete["/api/meetings/:id"] = { req in
            deleteMeeting(id: req.params[":id"] ?? "", repo: repo)
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
                return DTO.MeetingSummary(
                    id: m.id, started_at: m.startedAt, ended_at: m.endedAt,
                    duration_ms: m.durationMs, status: m.status.rawValue,
                    preview: segs.first?.text,
                    speaker_count: speakerIds.count
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
                boosted_text: m.boostedText,
                boosted_at: m.boostedAt
            )
            return jsonResponse(dto)
        } catch {
            return .internalServerError
        }
    }

    /// Fire-and-forget: kicks off per-segment Gemini polish on a background
    /// task and returns 200 immediately. The client polls GET /api/meetings/:id
    /// and watches `text_boost` on individual segments to decide when boost is
    /// complete (and whether to render polished or raw text in the existing
    /// TranscriptPane).
    private static func boostMeeting(id: String, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        do {
            guard let _ = try repo.meeting(id: id) else { return .notFound }
            let segments = try repo.segments(forMeeting: id)
            guard !segments.isEmpty else {
                return jsonResponse(DTO.BoostResponse(ok: false, error: "Empty transcript"))
            }
            FileLogger.log("boost: queued for \(id), \(segments.count) segments")

            let pairs: [(id: Int64, text: String)] = segments.compactMap {
                guard let sid = $0.id else { return nil }
                return (id: sid, text: $0.text)
            }
            Task.detached {
                do {
                    let map = try await BoostService.boostSegments(pairs)
                    for (sid, polished) in map {
                        try? repo.setSegmentBoost(segmentId: sid, text: polished)
                    }
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    try? repo.setBoostedText(meetingId: id, text: nil, at: now)
                    FileLogger.log("boost: done for \(id), \(map.count)/\(pairs.count) segments polished")
                } catch {
                    FileLogger.log("boost: failed for \(id): \(error)")
                }
            }
            return jsonResponse(DTO.BoostResponse(ok: true, error: nil))
        } catch {
            return jsonResponse(DTO.BoostResponse(ok: false, error: error.localizedDescription))
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
        return jsonResponse(DTO.Settings(boost_mode: BoostMode.isEnabled))
    }

    private static func settingsSet(req: HttpRequest) -> HttpResponse {
        do {
            let body = Data(req.body)
            let parsed = try JSONDecoder().decode(DTO.Settings.self, from: body)
            // UserDefaults is thread-safe; the @Published mirror in AppContext
            // is only relevant for SwiftUI bindings, not for backend reads.
            UserDefaults.standard.set(parsed.boost_mode, forKey: BoostMode.key)
            FileLogger.log("settings: boost_mode -> \(parsed.boost_mode)")
            return jsonResponse(DTO.Settings(boost_mode: parsed.boost_mode))
        } catch {
            return .badRequest(.text("\(error)"))
        }
    }

    private static func retranscribe(id: String) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        FileLogger.log("retranscribe: queued for \(id)")
        Task { @MainActor in
            await TranscriptionPipeline.shared.transcribe(meetingId: id)
        }
        return .ok(.text("queued"))
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
            let path = (kind == .video) ? m.videoPath : m.audioPath
            let dropboxRemote = (kind == .video) ? m.dropboxVideoPath : m.dropboxAudioPath
            let url = URL(fileURLWithPath: path)
            let contentType = (kind == .video) ? "video/quicktime" : "audio/wav"

            // Cloud fallback: the local file is gone but we have an archive
            // in Dropbox. We can't 302 to the Dropbox temporary link directly
            // because Dropbox serves the bytes with `Content-Type:
            // application/json`, which makes <video> refuse to play. Proxy
            // the bytes through ourselves with the right Content-Type, and
            // pass HTTP Range through unchanged so scrubbing still works.
            if !FileManager.default.fileExists(atPath: url.path), let remote = dropboxRemote {
                let rangeHeader = headers["range"] ?? headers["Range"]
                return proxyDropboxFile(remote: remote, contentType: contentType, range: rangeHeader)
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

    /// Synchronously fetch a Dropbox-archived file and return it as an
    /// HttpResponse with the correct Content-Type. We pass through HTTP
    /// Range so HTML5 <video> can scrub. The actual `temporary_link` request
    /// + the GET to that link are awaited on a detached task; the request
    /// thread blocks on a semaphore until the bytes are in memory.
    private static func proxyDropboxFile(remote: String, contentType: String, range: String?) -> HttpResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var bodyData: Data?
        var statusCode = 200
        var contentLength: String?
        var contentRange: String?

        Task.detached {
            defer { semaphore.signal() }
            do {
                let link = try await DropboxService.shared.getTemporaryLink(remotePath: remote)
                var req = URLRequest(url: link)
                req.httpMethod = "GET"
                req.timeoutInterval = 120
                if let range = range {
                    req.setValue(range, forHTTPHeaderField: "Range")
                }
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { return }
                statusCode = http.statusCode
                contentLength = http.value(forHTTPHeaderField: "Content-Length")
                contentRange = http.value(forHTTPHeaderField: "Content-Range")
                bodyData = data
            } catch {
                FileLogger.log("proxyDropboxFile: \(remote) failed: \(error)")
            }
        }
        semaphore.wait()

        guard let body = bodyData else { return .internalServerError }

        var responseHeaders: [String: String] = [
            "Content-Type": contentType,
            "Accept-Ranges": "bytes",
            "Content-Length": contentLength ?? "\(body.count)"
        ]
        if let cr = contentRange {
            responseHeaders["Content-Range"] = cr
        }

        let phrase = statusCode == 206 ? "Partial Content" : "OK"
        return .raw(statusCode, phrase, responseHeaders) { try $0.write(body) }
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
