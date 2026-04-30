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
                let firstSeg = try repo.segments(forMeeting: m.id).first
                return DTO.MeetingSummary(
                    id: m.id, started_at: m.startedAt, ended_at: m.endedAt,
                    duration_ms: m.durationMs, status: m.status.rawValue,
                    preview: firstSeg?.text
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
                                   start_ms: $0.startMs, end_ms: $0.endMs, text: $0.text)
                }
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
            let url = URL(fileURLWithPath: path)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let contentType = (kind == .video) ? "video/quicktime" : "audio/wav"

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
}
