import Foundation
@preconcurrency import Supabase

/// Builds a public share link for a finished meeting.
///
/// Flow: gate on a live session + a ready, non-empty transcript → verify the
/// transcript is actually in Supabase (awaitable `pushForShare`, which THROWS
/// so we never mint a link for data that never synced) → upload the compact
/// `.m4a` mix to the private `shares` Storage bucket → record the share via the
/// Worker → return the public URL. Everything is awaited and any failure throws
/// a user-facing error, so the Share button can surface exactly what went wrong.
@MainActor
enum ShareService {
    enum ShareError: LocalizedError {
        case notSignedIn
        case notReady
        case syncFailed(Error)
        case audioUnavailable
        case uploadFailed(Error)
        case workerFailed(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:     return "Sign in to share a link."
            case .notReady:        return "Transcribe the meeting before sharing it."
            case .syncFailed:      return "Could not sync the transcript, so the link was not created."
            case .audioUnavailable: return "The audio for this meeting is not available to share."
            case .uploadFailed:    return "Could not upload the audio for the link."
            case .workerFailed(let m): return "Could not create the share link. \(m)"
            }
        }
    }

    private static let createEndpoint =
        URL(string: "https://corder-api.empqwork.workers.dev/share/create")!
    private static let uploadURLEndpoint =
        URL(string: "https://corder-api.empqwork.workers.dev/share/upload-url")!

    /// A shared time range, in milliseconds from the meeting start. `nil` shares
    /// the whole meeting.
    struct Clip: Equatable { let startMs: Int; let endMs: Int }

    /// Create (or refresh) a share for `meetingId` and return the public URL.
    /// When `clip` is set, only that range is shared: the audio is cut to it and
    /// the Worker trims + re-bases the transcript, so the recipient gets exactly
    /// the shared slice and nothing else.
    static func createShare(meetingId: String, repo: MeetingRepository, clip: Clip? = nil) async throws -> URL {
        // 1. Live Supabase session (NOT the AppSettings.isSignedIn UserDefaults
        //    mirror, which can diverge from the real session).
        guard let session = SupabaseClientHolder.shared.auth.currentSession else {
            throw ShareError.notSignedIn
        }
        let jwt = session.accessToken

        // 2. Ready + has transcript. A share page with no segments is empty.
        guard let meeting = try? repo.meeting(id: meetingId), meeting.status == .ready else {
            throw ShareError.notReady
        }
        let segments = (try? repo.segments(forMeeting: meetingId)) ?? []
        guard !segments.isEmpty else { throw ShareError.notReady }

        // 3. Verified re-push (throws if the rows did not land in Supabase).
        do {
            try await SupabaseSync.pushForShare(meetingId: meetingId, repo: repo)
        } catch {
            throw ShareError.syncFailed(error)
        }

        // 4-5. Audio is BEST-EFFORT. For a normal `.ready` meeting `audio.wav`
        //    exists (produced at transcribe / stop) and the compact .m4a uploads
        //    fine. But a meeting whose source streams were deleted/archived has
        //    no audio to rebuild (audioM4A → nil), and a transcript is still
        //    perfectly shareable — so we share text-only rather than blocking
        //    the whole link. The share page hides the player when there is no
        //    audio.
        //
        //    The upload goes through a Worker-minted SIGNED URL, not the client
        //    session: writing to the `shares` bucket with the user's own JWT is
        //    rejected by Storage RLS (measured: 403 "new row violates
        //    row-level security policy"). The Worker also DERIVES the object key
        //    from the JWT, so the client never names its own path.
        var hasAudio = false
        let m4aURL = clip.map { MediaExporter.audioClipM4A(meetingId: meetingId, startMs: $0.startMs, endMs: $0.endMs) }
            ?? MediaExporter.audioM4A(meetingId: meetingId)
        if let m4aURL {
            do {
                let data = try Data(contentsOf: m4aURL)
                try await uploadAudio(data: data, meetingId: meetingId, jwt: jwt, clip: clip)
                hasAudio = true
            } catch {
                FileLogger.log("ShareService: audio upload failed for \(meetingId), sharing text-only: \(error)")
            }
        } else {
            FileLogger.log("ShareService: no audio on disk for \(meetingId), sharing text-only")
        }

        // 6. Record the share via the Worker (JWT-authed).
        var req = URLRequest(url: createEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        var payload: [String: Any] = [
            "meeting_id": meetingId,
            "has_audio": hasAudio,
            "owner_name": AppSettings.userName ?? AppSettings.userEmail ?? "",
        ]
        if let clip {
            payload["clip_start_ms"] = clip.startMs
            payload["clip_end_ms"] = clip.endMs
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            throw ShareError.workerFailed(String(body.prefix(200)))
        }
        struct CreateResp: Decodable { let ok: Bool; let url: String? }
        guard let decoded = try? JSONDecoder().decode(CreateResp.self, from: respData),
              decoded.ok, let urlStr = decoded.url, let url = URL(string: urlStr) else {
            throw ShareError.workerFailed("unexpected response")
        }
        FileLogger.log("ShareService: created share for \(meetingId) -> \(urlStr)")
        return url
    }

    /// Ask the Worker for a one-shot signed upload URL and PUT the audio to it.
    /// Throws on any failure; the caller treats audio as best-effort.
    private static func uploadAudio(data: Data, meetingId: String, jwt: String, clip: Clip?) async throws {
        var req = URLRequest(url: uploadURLEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        // The clip range must match what /share/create records, or the signed
        // upload key and the row's key diverge and the page can't find the audio.
        var uploadBody: [String: Any] = ["meeting_id": meetingId]
        if let clip {
            uploadBody["clip_start_ms"] = clip.startMs
            uploadBody["clip_end_ms"] = clip.endMs
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: uploadBody)

        let (signData, signResp) = try await URLSession.shared.data(for: req)
        guard let signHTTP = signResp as? HTTPURLResponse,
              (200..<300).contains(signHTTP.statusCode) else {
            let body = String(data: signData, encoding: .utf8) ?? ""
            throw ShareError.uploadFailed(
                NSError(domain: "ShareService", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "sign: \(body.prefix(200))"]))
        }
        struct SignResp: Decodable { let ok: Bool; let upload_url: String? }
        guard let signed = try? JSONDecoder().decode(SignResp.self, from: signData),
              signed.ok, let urlStr = signed.upload_url, let putURL = URL(string: urlStr) else {
            throw ShareError.uploadFailed(
                NSError(domain: "ShareService", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "sign: unexpected response"]))
        }

        var put = URLRequest(url: putURL)
        put.httpMethod = "PUT"
        put.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        put.setValue("3600", forHTTPHeaderField: "cache-control")
        // A long meeting's .m4a is a few tens of MB on a possibly slow uplink.
        put.timeoutInterval = 300
        let (putData, putResp) = try await URLSession.shared.upload(for: put, from: data)
        guard let putHTTP = putResp as? HTTPURLResponse,
              (200..<300).contains(putHTTP.statusCode) else {
            let body = String(data: putData, encoding: .utf8) ?? ""
            throw ShareError.uploadFailed(
                NSError(domain: "ShareService", code: 3,
                        userInfo: [NSLocalizedDescriptionKey:
                            "put \((putResp as? HTTPURLResponse)?.statusCode ?? -1): \(body.prefix(200))"]))
        }
        FileLogger.log("ShareService: uploaded audio for \(meetingId) (\(data.count / 1024) KB)")
    }
}
