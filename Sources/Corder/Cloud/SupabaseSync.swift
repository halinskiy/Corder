import Foundation
@preconcurrency import Supabase

/// Hybrid local-first / cloud-synced repository. Local GRDB stays
/// as the read source-of-truth (offline OK, fast, instant), but
/// every write that lands locally is mirrored to Supabase so the
/// same user can re-install / open Corder on another Mac and see
/// their library. Sign-in `pullAll` reconciles the other way.
///
/// Why hybrid instead of a full repository swap:
/// `MeetingRepository` has 30+ specialised methods — `setTitle`,
/// `setSummary`, `setRawTurnsCache`, `setSegmentBoost`, etc. — and
/// rewriting them all on a network round-trip would hurt UX
/// (every typed letter would await Postgres) and lose offline
/// support. Hybrid keeps local reads instant and only pays the
/// network cost on the write path (fire-and-forget, errors logged
/// and retried on next pull).
///
/// What's NOT synced (intentional, for now):
/// - `videoPath` / `audioPath` (local filesystem paths). The cloud
///   replacement is `recordings_meta` rows + Storage object keys —
///   different shape, mapped at upload time.
/// - `dropbox_*` columns. Dropbox path was the legacy archive sink;
///   the Storage bucket replaces it. Nothing reads dropbox_* in the
///   new flow.
/// - `gemini_raw_turns` / `audio_hash`. Cache fields — they exist
///   to avoid re-transcribing the SAME audio on the same Mac. After
///   a cross-device install the audio file isn't present locally
///   anyway, so the cache wouldn't help.
@MainActor
enum SupabaseSync {

    /// Fire-and-forget background push. Logs failures, never throws.
    /// Use for write-through mirroring of local mutations.
    static func push(_ work: @escaping () async throws -> Void) {
        Task.detached {
            do { try await work() }
            catch { FileLogger.log("SupabaseSync: push failed — \(error)") }
        }
    }

    /// Current Supabase user id, or nil when signed out. Inserts
    /// without a session are skipped (instead of crashing) so a
    /// pre-sign-in launch can still mutate the local DB.
    static func userId() -> UUID? {
        return SupabaseClientHolder.shared.auth.currentUser?.id
    }

    // MARK: - Row shapes (Codable mirrors of the Postgres schema)

    /// Row shape used for INSERT / UPDATE / pull. Field names match
    /// the Postgres columns 1:1 so the SDK's auto-encoder JSONifies
    /// them straight onto the wire.
    struct MeetingRow: Codable, Sendable {
        let id: String
        let user_id: UUID
        let title: String?
        let started_at: String              // ISO-8601 UTC
        let ended_at: String?
        let duration_ms: Int64
        let status: String
        let has_video: Bool
        let pinned: Bool
        let archived_at: String?
        let viewed_at: String?
        let provider: String?
    }

    struct SpeakerRow: Codable, Sendable {
        let id: UUID
        let meeting_id: String
        let label: String
        let display_name: String?
        let kind: String
        let position: Int
    }

    struct SegmentRow: Codable, Sendable {
        let id: UUID
        let meeting_id: String
        let speaker_id: UUID
        let start_ms: Int64
        let end_ms: Int64
        let text: String
        let position: Int
    }

    struct SummaryRow: Codable, Sendable {
        let meeting_id: String
        let markdown: String
        let model: String?
    }

    struct RecordingMetaRow: Codable, Sendable {
        let meeting_id: String
        let kind: String                    // mic / system / system_sck / mix / video
        let storage_path: String
        let size_bytes: Int64?
        let duration_ms: Int64?
    }

    // MARK: - Mapping helpers

    /// Convert a local `Meeting` to its remote row, attaching the
    /// signed-in user id. Returns nil when signed out (caller should
    /// skip the push and try again on next sign-in).
    private static func toRow(_ m: Meeting) -> MeetingRow? {
        guard let uid = userId() else { return nil }
        let iso: (Int64?) -> String? = { ms in
            guard let ms else { return nil }
            return Self.isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
        }
        return MeetingRow(
            id: m.id,
            user_id: uid,
            title: m.title,
            started_at: iso(m.startedAt) ?? Self.isoFormatter.string(from: Date()),
            ended_at: iso(m.endedAt),
            duration_ms: m.durationMs ?? 0,
            // The server's `meetings_status_check` constraint predates the
            // `preroll` status, so pushing it raw 23514-fails the whole row
            // (the meeting never syncs). `preroll` is a transient pre-record
            // buffer anyway, so map it to `recording` for the server; once
            // the meeting finishes it updates to ready/failed normally.
            status: m.status == .preroll ? MeetingStatus.recording.rawValue : m.status.rawValue,
            has_video: !m.videoPath.isEmpty,
            pinned: m.pinnedAt != nil,
            archived_at: iso(m.archivedAt),
            viewed_at: iso(m.viewedAt),
            provider: nil
        )
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Mutations (write-through)

    /// Insert OR update a meeting on the server. Idempotent — uses
    /// Postgres `on conflict (id) do update`. Safe to call repeatedly.
    static func upsertMeeting(_ m: Meeting) {
        guard let row = toRow(m) else { return }
        push {
            try await SupabaseClientHolder.shared
                .from("meetings")
                .upsert(row, onConflict: "id")
                .execute()
        }
    }

    /// Drop a meeting + all its dependents (ON DELETE CASCADE
    /// takes care of speakers/segments/summaries/recordings_meta).
    static func deleteMeeting(id: String) {
        push {
            try await SupabaseClientHolder.shared
                .from("meetings")
                .delete()
                .eq("id", value: id)
                .execute()
        }
    }

    /// Replace the speakers list for a meeting. We delete-then-insert
    /// rather than diff because diarization re-runs can re-number /
    /// re-shape the speaker set and the local code already treats
    /// `setSpeakers` as a wholesale replacement.
    static func replaceSpeakers(_ speakers: [Speaker], meetingId: String) {
        push {
            try await SupabaseClientHolder.shared
                .from("speakers")
                .delete()
                .eq("meeting_id", value: meetingId)
                .execute()
            guard !speakers.isEmpty else { return }
            let rows: [SpeakerRow] = speakers.enumerated().map { idx, s in
                // Local Speaker has no `kind` / `position` fields,
                // so we derive them on the way out: label "user"
                // becomes kind="user", everything else "other";
                // position is the array index (the local repo
                // returns speakers in display order already).
                SpeakerRow(
                    id: UUID(uuidString: s.id) ?? UUID(),
                    meeting_id: meetingId,
                    label: s.label,
                    display_name: s.customName,
                    kind: s.label == "user" ? "user" : "other",
                    position: idx)
            }
            try await SupabaseClientHolder.shared
                .from("speakers")
                .insert(rows)
                .execute()
        }
    }

    /// Replace the segments list for a meeting. Same wholesale
    /// pattern as `replaceSpeakers` — the local pipeline writes the
    /// entire transcript at once after each run.
    static func replaceSegments(_ segments: [Segment], meetingId: String,
                                speakerIdByLocalId: [String: UUID]) {
        push {
            try await Self._replaceSegmentsAwait(
                segments, meetingId: meetingId, speakerIdByLocalId: speakerIdByLocalId)
        }
    }

    private static func _replaceSegmentsAwait(_ segments: [Segment], meetingId: String,
                                              speakerIdByLocalId: [String: UUID]) async throws {
        try await SupabaseClientHolder.shared
            .from("segments")
            .delete()
            .eq("meeting_id", value: meetingId)
            .execute()
        guard !segments.isEmpty else { return }
        let rows: [SegmentRow] = segments.enumerated().compactMap { idx, s in
            guard let spk = speakerIdByLocalId[s.speakerId] else { return nil }
            return SegmentRow(
                id: UUID(),
                meeting_id: meetingId,
                speaker_id: spk,
                start_ms: s.startMs,
                end_ms: s.endMs,
                text: s.text,
                position: idx)
        }
        guard !rows.isEmpty else { return }
        try await SupabaseClientHolder.shared
            .from("segments")
            .insert(rows)
            .execute()
    }

    /// Push speakers AND segments in a single task so segments can't
    /// land before their referenced speakers (which is exactly the
    /// foreign-key violation 23503 we kept seeing on every successful
    /// transcribe: `segments_speaker_id_fkey`). The two helpers were
    /// independent `push` calls before — fire-and-forget, no
    /// ordering guarantee.
    static func replaceSpeakersAndSegments(
        speakers: [Speaker],
        segments: [Segment],
        meetingId: String,
        speakerIdByLocalId: [String: UUID]
    ) {
        push {
            try await SupabaseClientHolder.shared
                .from("speakers")
                .delete()
                .eq("meeting_id", value: meetingId)
                .execute()
            if !speakers.isEmpty {
                let rows: [SpeakerRow] = speakers.enumerated().map { idx, s in
                    // CRITICAL: use the SAME UUID the segment-side
                    // lookup will see. Re-resolving `UUID(uuidString:)
                    // ?? UUID()` here would yield a fresh random ID
                    // whenever `s.id` isn't a valid UUID string,
                    // leaving segments pointing at a non-existent
                    // speaker row → FK 23503. The caller's
                    // `speakerIdByLocalId` is the single source of
                    // truth; fall back to a deterministic same-call
                    // UUID only as a last resort (and store it in
                    // the map so the segment side will agree).
                    let resolved = speakerIdByLocalId[s.id] ?? UUID(uuidString: s.id) ?? UUID()
                    return SpeakerRow(
                        id: resolved,
                        meeting_id: meetingId,
                        label: s.label,
                        display_name: s.customName,
                        kind: s.label == "user" ? "user" : "other",
                        position: idx)
                }
                try await SupabaseClientHolder.shared
                    .from("speakers")
                    .insert(rows)
                    .execute()
            }
            try await Self._replaceSegmentsAwait(
                segments, meetingId: meetingId, speakerIdByLocalId: speakerIdByLocalId)
        }
    }

    /// Set / clear the summary markdown for a meeting. Upserts the
    /// `summaries` row (PK = meeting_id).
    static func setSummary(_ markdown: String?, meetingId: String, model: String? = nil) {
        push {
            if let md = markdown, !md.isEmpty {
                let row = SummaryRow(meeting_id: meetingId, markdown: md, model: model)
                try await SupabaseClientHolder.shared
                    .from("summaries")
                    .upsert(row, onConflict: "meeting_id")
                    .execute()
            } else {
                try await SupabaseClientHolder.shared
                    .from("summaries")
                    .delete()
                    .eq("meeting_id", value: meetingId)
                    .execute()
            }
        }
    }

    // MARK: - Storage upload

    /// Upload a local audio/video file to `recordings/<uid>/<mid>/<kind>.<ext>`
    /// and insert/upsert the matching `recordings_meta` row. Logs +
    /// swallows errors (the local file still works for in-app
    /// playback even if the cloud push fails). Returns the object
    /// key so callers can pin it locally if needed.
    @discardableResult
    static func uploadRecording(meetingId: String,
                                kind: String,
                                fileURL: URL,
                                durationMs: Int64?) async -> String? {
        // Audio backup is temporarily off. Supabase Storage Free
        // plan caps single-shot upload at 50 MB and a typical
        // 7-min recording's `system.wav` is ~80 MB → 413 every
        // time. Migration to Cloudflare R2 (no per-file cap, ∞
        // egress, free 10 GB) is queued; once R2 is enabled in the
        // Dashboard the env flag below flips and uploads resume.
        // Until then: recordings stay local-only (transcript still
        // syncs to Supabase via the `meetings` / `speakers` /
        // `segments` tables; only the playback audio is missing
        // from the cloud mirror).
        let cloudAudioEnabled = UserDefaults.standard.object(forKey: "Corder.set.cloudAudioBackup") as? Bool ?? false
        if !cloudAudioEnabled {
            FileLogger.log("SupabaseSync.uploadRecording(\(kind)) skipped — cloud audio backup disabled pending R2 migration")
            return nil
        }
        guard let uid = userId() else { return nil }
        let ext = fileURL.pathExtension
        // RLS on `storage.objects` compares the first path segment to
        // `auth.uid()::text` — Postgres renders UUIDs LOWERCASE. Swift
        // `UUID.uuidString` returns UPPERCASE-HYPHENED, which made
        // every upload fail with "new row violates row-level security
        // policy" until we matched the case here.
        let key = "\(uid.uuidString.lowercased())/\(meetingId)/\(kind).\(ext)"
        do {
            let data = try Data(contentsOf: fileURL)
            let opts = FileOptions(cacheControl: "3600", upsert: true)
            _ = try await SupabaseClientHolder.shared.storage
                .from("recordings")
                .upload(key, data: data, options: opts)
            let size = (try? FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? nil
            let meta = RecordingMetaRow(
                meeting_id: meetingId,
                kind: kind,
                storage_path: key,
                size_bytes: size,
                duration_ms: durationMs)
            try await SupabaseClientHolder.shared
                .from("recordings_meta")
                .upsert(meta, onConflict: "meeting_id,kind")
                .execute()
            return key
        } catch {
            FileLogger.log("SupabaseSync.uploadRecording(\(kind)) failed: \(error)")
            return nil
        }
    }

    // MARK: - Account deletion (GDPR)

    /// Wipe every row owned by the signed-in user in the cloud
    /// (meetings cascade-clear speakers / segments / summaries /
    /// recordings_meta via FK; profile row goes too) plus every
    /// audio/video object under `recordings/<uid>/`. The
    /// `auth.users` row itself stays — Supabase Free doesn't let a
    /// regular client delete its own auth row, only the
    /// service-role key can. The user's PII is gone either way;
    /// the dangling auth row carries only the email + sub claim
    /// and we can purge it via a follow-up Edge Function later.
    static func deleteEverything() async throws {
        guard let uid = userId() else { return }
        let uidString = uid.uuidString.lowercased()

        // Postgres cascade fans out from meetings; profile has its
        // own FK on auth.users so we delete it explicitly.
        try await SupabaseClientHolder.shared
            .from("meetings").delete().eq("user_id", value: uid).execute()
        try await SupabaseClientHolder.shared
            .from("profiles").delete().eq("id", value: uid).execute()

        // Storage objects under `<uid>/...`. List + remove. Iterate
        // in pages to handle users with many recordings.
        do {
            let listed = try await SupabaseClientHolder.shared.storage
                .from("recordings")
                .list(path: uidString,
                      options: SearchOptions(limit: 1000, offset: 0))
            // The Supabase list() returns FILE entries under that
            // prefix. We need to recurse into subfolders (one per
            // meeting). Cheap recursion — list each subfolder and
            // batch-remove the leaves.
            var paths: [String] = []
            for entry in listed {
                let sub = "\(uidString)/\(entry.name)"
                if let _ = entry.id {
                    paths.append(sub)
                } else {
                    let inner = try await SupabaseClientHolder.shared.storage
                        .from("recordings")
                        .list(path: sub,
                              options: SearchOptions(limit: 1000, offset: 0))
                    for f in inner { paths.append("\(sub)/\(f.name)") }
                }
            }
            if !paths.isEmpty {
                _ = try await SupabaseClientHolder.shared.storage
                    .from("recordings")
                    .remove(paths: paths)
                FileLogger.log("SupabaseSync.deleteEverything: removed \(paths.count) storage objects")
            }
        } catch {
            FileLogger.log("SupabaseSync.deleteEverything: storage cleanup failed — \(error)")
        }

        // Local clear: forget the sticky flags so a re-sign-in
        // under a different email starts cleanly.
        AppSettings.setCloudBackfillDone(false)
        AppSettings.setLastSyncedUserId(nil)

        try await SupabaseClientHolder.shared.auth.signOut()
    }

    // MARK: - One-time backfill of pre-Supabase local meetings

    /// Walk every local meeting and push its row + speakers +
    /// segments + audio files to Supabase. Idempotent (uses upsert)
    /// so re-running on a partially-synced library doesn't
    /// duplicate anything. Sets `AppSettings.cloudBackfillDone` on
    /// success so subsequent launches skip the work.
    static func backfillIfNeeded(repo: MeetingRepository) async {
        guard userId() != nil else { return }
        if AppSettings.cloudBackfillDone { return }
        let meetings = (try? repo.listMeetings()) ?? []
        guard !meetings.isEmpty else {
            AppSettings.setCloudBackfillDone(true)
            return
        }
        // Backfill is GATED behind an explicit user opt-in. On a
        // dev box where several Google accounts share one local
        // SQLite, the first sign-in shouldn't silently claim every
        // historical recording as that account's — the user has to
        // say "yes, these are mine". One-user-one-Mac users hit
        // the toggle once and forget.
        guard AppSettings.cloudBackfillOptedIn else {
            FileLogger.log("SupabaseSync.backfill: skipped — user has not opted in (set Corder.user.cloudBackfillOptIn to true)")
            return
        }
        FileLogger.log("SupabaseSync.backfill: pushing \(meetings.count) local meetings to cloud")
        // 50 MB ceiling: Free-tier Supabase Storage caps single-shot
        // REST uploads around there. Bigger files need resumable
        // upload (TUS) — out of scope for backfill, skipped with a
        // log line so we know which files to chase later.
        let uploadCeilingBytes: Int64 = 40 * 1024 * 1024
        for m in meetings {
            // SYNCHRONOUS chain (not fire-and-forget) so meetings
            // commit BEFORE speakers, speakers BEFORE segments.
            // The earlier `push {}` helpers fired all three in
            // parallel via Task.detached and produced FK violations
            // (`segments_speaker_id_fkey`) when segments raced
            // ahead of their speaker rows.
            do {
                guard let row = toRow(m) else { continue }
                try await SupabaseClientHolder.shared
                    .from("meetings")
                    .upsert(row, onConflict: "id")
                    .execute()
            } catch {
                FileLogger.log("SupabaseSync.backfill: meeting \(m.id) upsert failed — \(error)")
                continue
            }
            let speakers = (try? repo.speakers(forMeeting: m.id)) ?? []
            let segments = (try? repo.segments(forMeeting: m.id)) ?? []
            var speakerUUIDs: [String: UUID] = [:]
            for s in speakers { speakerUUIDs[s.id] = UUID(uuidString: s.id) ?? UUID() }
            do {
                try await SupabaseClientHolder.shared
                    .from("speakers")
                    .delete()
                    .eq("meeting_id", value: m.id)
                    .execute()
                if !speakers.isEmpty {
                    let rows: [SpeakerRow] = speakers.enumerated().map { idx, s in
                        SpeakerRow(
                            id: speakerUUIDs[s.id]!,
                            meeting_id: m.id,
                            label: s.label,
                            display_name: s.customName,
                            kind: s.label == "user" ? "user" : "other",
                            position: idx)
                    }
                    try await SupabaseClientHolder.shared
                        .from("speakers")
                        .insert(rows)
                        .execute()
                }
            } catch {
                FileLogger.log("SupabaseSync.backfill: speakers for \(m.id) failed — \(error)")
                continue
            }
            do {
                try await SupabaseClientHolder.shared
                    .from("segments")
                    .delete()
                    .eq("meeting_id", value: m.id)
                    .execute()
                if !segments.isEmpty {
                    let rows: [SegmentRow] = segments.enumerated().compactMap { idx, s in
                        guard let spk = speakerUUIDs[s.speakerId] else { return nil }
                        return SegmentRow(
                            id: UUID(),
                            meeting_id: m.id,
                            speaker_id: spk,
                            start_ms: s.startMs,
                            end_ms: s.endMs,
                            text: s.text,
                            position: idx)
                    }
                    if !rows.isEmpty {
                        try await SupabaseClientHolder.shared
                            .from("segments")
                            .insert(rows)
                            .execute()
                    }
                }
            } catch {
                FileLogger.log("SupabaseSync.backfill: segments for \(m.id) failed — \(error)")
            }
            // Audio files — skip huge ones (Free-tier REST upload cap).
            let dir = AppPaths.recordingDir(for: m.id)
            let fm = FileManager.default
            for (kind, name) in [("mix", "audio.wav"),
                                 ("mic", "mic.wav"),
                                 ("system", "system.wav")] {
                let file = dir.appendingPathComponent(name)
                guard fm.fileExists(atPath: file.path) else { continue }
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
                if size > uploadCeilingBytes {
                    FileLogger.log("SupabaseSync.backfill: skipping \(m.id)/\(kind) — \(size) bytes > 40MB ceiling (needs resumable upload)")
                    continue
                }
                await uploadRecording(meetingId: m.id, kind: kind,
                                      fileURL: file, durationMs: m.durationMs)
            }
        }
        AppSettings.setCloudBackfillDone(true)
        FileLogger.log("SupabaseSync.backfill: complete")
    }

    // MARK: - Pull on sign-in

    /// Replace the local meetings cache with whatever the server has
    /// for this user. Called from the sign-in completion / launch
    /// path. Local-only fields (videoPath/audioPath, dropbox_*,
    /// gemini_raw_turns) are left alone for existing rows; brand-new
    /// rows from the cloud get empty paths (they live in Storage
    /// only — playback will hit the Storage signed-URL path).
    static func pullAll(repo: MeetingRepository) async {
        guard let uid = userId() else { return }

        // NOTE: we used to wipe the local cache on account-switch
        // to keep account A's recordings invisible after B signs
        // in on the same Mac. Rolled back because the wipe is
        // DESTRUCTIVE — the local SQLite is the only home for
        // pre-Supabase recordings, and account-switch is a normal
        // dev/test workflow on a shared Mac. Cross-user isolation
        // for the typical "one user per Mac" case is enforced
        // server-side via RLS; on a multi-Google-account dev box
        // the user has to live with the local SQLite showing
        // everyone's rows. Multi-account local-folder isolation
        // can come back later if it's actually needed.
        let uidString = uid.uuidString
        if AppSettings.lastSyncedUserId != uidString {
            FileLogger.log("SupabaseSync.pullAll: user changed (\(AppSettings.lastSyncedUserId ?? "nil") → \(uidString)) — keeping local cache, resetting backfill flag")
            AppSettings.setCloudBackfillDone(false)
            AppSettings.setLastSyncedUserId(uidString)
        }

        do {
            let rows: [MeetingRow] = try await SupabaseClientHolder.shared
                .from("meetings")
                .select()
                .execute()
                .value
            FileLogger.log("SupabaseSync.pullAll: fetched \(rows.count) meetings from cloud")
            for r in rows {
                let existing = try? repo.meeting(id: r.id)
                let startedMs = Int64((Self.isoFormatter.date(from: r.started_at)?.timeIntervalSince1970 ?? 0) * 1000)
                let endedMs = r.ended_at.flatMap {
                    Self.isoFormatter.date(from: $0).map { Int64($0.timeIntervalSince1970 * 1000) }
                }
                let archivedMs = r.archived_at.flatMap {
                    Self.isoFormatter.date(from: $0).map { Int64($0.timeIntervalSince1970 * 1000) }
                }
                let viewedMs = r.viewed_at.flatMap {
                    Self.isoFormatter.date(from: $0).map { Int64($0.timeIntervalSince1970 * 1000) }
                }
                let status = MeetingStatus(rawValue: r.status) ?? .ready
                var m = existing ?? Meeting(
                    id: r.id,
                    startedAt: startedMs,
                    videoPath: "",
                    audioPath: "",
                    status: status)
                m.title = r.title ?? m.title
                m.endedAt = endedMs ?? m.endedAt
                m.durationMs = r.duration_ms
                m.status = status
                m.archivedAt = archivedMs
                m.pinnedAt = r.pinned ? (m.pinnedAt ?? Int64(Date().timeIntervalSince1970 * 1000)) : nil
                m.viewedAt = viewedMs
                do {
                    if existing == nil { try repo.insertMeeting(m) }
                    else                { try repo.updateMeeting(m) }
                } catch {
                    FileLogger.log("SupabaseSync.pullAll: failed to persist \(r.id): \(error)")
                }
            }
        } catch {
            FileLogger.log("SupabaseSync.pullAll: fetch failed — \(error)")
        }
    }
}
