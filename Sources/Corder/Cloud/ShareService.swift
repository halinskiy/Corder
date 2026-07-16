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

    /// Create (or refresh) a share for `meetingId` and return the public URL.
    static func createShare(meetingId: String, repo: MeetingRepository) async throws -> URL {
        // 1. Live Supabase session (NOT the AppSettings.isSignedIn UserDefaults
        //    mirror, which can diverge from the real session).
        guard let session = SupabaseClientHolder.shared.auth.currentSession else {
            throw ShareError.notSignedIn
        }
        guard let uid = SupabaseSync.userId() else { throw ShareError.notSignedIn }
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

        // 4. Compact .m4a. For a `.ready` meeting `audio.wav` exists (produced at
        //    transcribe / stop), so the export finds it. A Dropbox-archived
        //    meeting whose sources are off-disk yields nil → audioUnavailable.
        guard let m4aURL = MediaExporter.audioM4A(meetingId: meetingId) else {
            throw ShareError.audioUnavailable
        }

        // 5. Upload to the private `shares` bucket at <uid>/<mid>.m4a.
        //    Lowercased UUID to match the storage.objects RLS folder check.
        let audioKey = "\(uid.uuidString.lowercased())/\(meetingId).m4a"
        do {
            let data = try Data(contentsOf: m4aURL)
            _ = try await SupabaseClientHolder.shared.storage
                .from("shares")
                .upload(audioKey, data: data,
                        options: FileOptions(cacheControl: "3600", upsert: true))
        } catch {
            throw ShareError.uploadFailed(error)
        }

        // 6. Record the share via the Worker (JWT-authed).
        var req = URLRequest(url: createEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let payload: [String: Any] = [
            "meeting_id": meetingId,
            "audio_key": audioKey,
            "owner_name": AppSettings.userName ?? AppSettings.userEmail ?? "",
        ]
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
}
