import Foundation
import GRDB

struct MeetingRepository {
    let dbq: DatabaseQueue

    func insertMeeting(_ m: Meeting) throws {
        try dbq.write { try m.insert($0) }
        // Mirror to Supabase (fire-and-forget). Skipped while
        // signed out — the local row stays, next sign-in's
        // upsert push will catch it up.
        Task { @MainActor in SupabaseSync.upsertMeeting(m) }
    }

    func updateMeeting(_ m: Meeting) throws {
        try dbq.write { try m.update($0) }
        Task { @MainActor in SupabaseSync.upsertMeeting(m) }
    }

    func deleteMeeting(id: String) throws {
        try dbq.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
        }
        Task { @MainActor in SupabaseSync.deleteMeeting(id: id) }
    }

    /// Wipe every meeting (plus its speakers/segments via the
    /// ON DELETE CASCADE foreign keys) from the local cache.
    /// Used when a different Supabase account signs in on the
    /// same Mac — the cloud pull will rebuild the right rows for
    /// the new user immediately after. Does NOT push to Supabase
    /// (server data belongs to whichever user owned it; we're
    /// only clearing the local mirror).
    func purgeAllMeetings() throws {
        try dbq.write { db in
            try db.execute(sql: "DELETE FROM meetings")
        }
    }

    func meeting(id: String) throws -> Meeting? {
        try dbq.read { try Meeting.fetchOne($0, key: id) }
    }

    /// Sum of recorded seconds since `sinceMs` for each transcription
    /// class. `nil`-class rows (legacy meetings transcribed before the
    /// v18 column shipped) are counted under "advanced" — we'd rather
    /// over-credit than silently let billable runs slip through.
    /// `archivedAt` rows still count: archive ≠ refund.
    func usageSecondsByClass(sinceMs: Int64) throws -> [String: Int64] {
        try dbq.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT COALESCE(transcription_class, 'advanced') AS cls,
                       COALESCE(SUM(duration_ms), 0) AS dur_ms
                  FROM meetings
                 WHERE transcribed_at IS NOT NULL
                   AND transcribed_at >= ?
                 GROUP BY cls
                """, arguments: [sinceMs])
            var out: [String: Int64] = ["advanced": 0, "local": 0]
            for r in rows {
                let cls: String = r["cls"] ?? "advanced"
                let durMs: Int64 = r["dur_ms"] ?? 0
                out[cls, default: 0] += durMs / 1000
            }
            return out
        }
    }

    func listMeetings() throws -> [Meeting] {
        try dbq.read { db in
            try Meeting
                .filter(Column("archived_at") == nil)
                .order(Column("started_at").desc)
                .fetchAll(db)
        }
    }

    /// Sidebar summary row — everything the meetings list needs in a
    /// single round trip per column. Replaces the N+1 path that fetched
    /// every meeting and then re-queried segments + speakers per row;
    /// at 50+ meetings that was ≥150 SQLite reads on each
    /// /api/meetings poll.
    struct SummaryRow {
        let id: String
        let startedAt: Int64
        let endedAt: Int64?
        let durationMs: Int64?
        let status: String
        let title: String?
        let preview: String?
        let speakerCount: Int
        let speakerNames: String?
        let pinnedAt: Int64?
        let viewedAt: Int64?
    }

    func listMeetingSummaries() throws -> [SummaryRow] {
        try dbq.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    m.id,
                    m.started_at,
                    m.ended_at,
                    m.duration_ms,
                    m.status,
                    m.title,
                    m.pinned_at,
                    m.viewed_at,
                    (SELECT s.text
                       FROM segments s
                       WHERE s.meeting_id = m.id
                       ORDER BY s.start_ms ASC
                       LIMIT 1) AS preview,
                    (SELECT COUNT(DISTINCT s.speaker_id)
                       FROM segments s
                       WHERE s.meeting_id = m.id) AS speaker_count,
                    (SELECT GROUP_CONCAT(name, ' · ')
                       FROM (
                         SELECT DISTINCT
                            COALESCE(NULLIF(TRIM(sp.custom_name), ''), sp.label) AS name
                         FROM speakers sp
                         WHERE sp.meeting_id = m.id
                           AND EXISTS (
                             SELECT 1 FROM segments s
                             WHERE s.meeting_id = m.id
                               AND s.speaker_id = sp.id
                           )
                       )) AS speaker_names
                FROM meetings m
                WHERE m.archived_at IS NULL
                ORDER BY (m.pinned_at IS NULL), m.pinned_at DESC, m.started_at DESC
            """)
            return rows.map { r in
                SummaryRow(
                    id: r["id"] ?? "",
                    startedAt: r["started_at"] ?? 0,
                    endedAt: r["ended_at"],
                    durationMs: r["duration_ms"],
                    status: r["status"] ?? "",
                    title: r["title"],
                    preview: r["preview"],
                    speakerCount: r["speaker_count"] ?? 0,
                    speakerNames: r["speaker_names"],
                    pinnedAt: r["pinned_at"],
                    viewedAt: r["viewed_at"]
                )
            }
        }
    }

    /// All archived meetings, newest-archived first. Used by the archive
    /// view to show the 7-day grace bin.
    func listArchived() throws -> [Meeting] {
        try dbq.read { db in
            try Meeting
                .filter(Column("archived_at") != nil)
                .order(Column("archived_at").desc)
                .fetchAll(db)
        }
    }

    func setArchived(meetingId: String, archivedAt: Int64?) throws {
        try dbq.write { db in
            try db.execute(sql: "UPDATE meetings SET archived_at = ? WHERE id = ?",
                           arguments: [archivedAt, meetingId])
        }
        if let m = try meeting(id: meetingId) {
            Task { @MainActor in SupabaseSync.upsertMeeting(m) }
        }
    }

    func setPinned(meetingId: String, pinnedAt: Int64?) throws {
        try dbq.write { db in
            try db.execute(sql: "UPDATE meetings SET pinned_at = ? WHERE id = ?",
                           arguments: [pinnedAt, meetingId])
        }
        if let m = try meeting(id: meetingId) {
            Task { @MainActor in SupabaseSync.upsertMeeting(m) }
        }
    }

    /// Stamp `viewed_at` with the current time, but only if it's still
    /// null — once seen, the row stays seen. Used by the GET detail
    /// route to mark a meeting as opened the first time the user looks
    /// at it.
    func markViewedIfNew(meetingId: String, atMs: Int64) throws {
        try dbq.write { db in
            try db.execute(sql: "UPDATE meetings SET viewed_at = ? WHERE id = ? AND viewed_at IS NULL",
                           arguments: [atMs, meetingId])
        }
    }

    /// IDs whose `archived_at` is older than the given cutoff (ms).
    /// Used at launch to decide which archived rows to hard-delete.
    func archivedOlderThan(_ cutoffMs: Int64) throws -> [String] {
        try dbq.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM meetings
                WHERE archived_at IS NOT NULL AND archived_at < ?
            """, arguments: [cutoffMs])
        }
    }

    /// Active (non-archived) meetings transcribed before `cutoffMs` that
    /// already have their raw Gemini turns cached. The originals
    /// (mic.wav + system.wav) can be deleted from disk for those —
    /// re-transcribe will hit the cache and never need the audio again.
    func transcribedWithCacheOlderThan(_ cutoffMs: Int64) throws -> [String] {
        try dbq.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM meetings
                WHERE archived_at IS NULL
                  AND transcribed_at IS NOT NULL
                  AND transcribed_at < ?
                  AND gemini_raw_turns IS NOT NULL
                  AND audio_hash IS NOT NULL
            """, arguments: [cutoffMs])
        }
    }

    func insertSpeaker(_ s: Speaker) throws {
        try dbq.write { try s.insert($0) }
    }

    func renameSpeaker(speakerId: String, customName: String?) throws {
        try dbq.write { db in
            try db.execute(sql: "UPDATE speakers SET custom_name = ? WHERE id = ?",
                           arguments: [customName, speakerId])
        }
    }

    func speakers(forMeeting id: String) throws -> [Speaker] {
        try dbq.read { db in
            try Speaker
                .filter(Column("meeting_id") == id)
                .order(Column("label"))
                .fetchAll(db)
        }
    }

    func insertSegment(_ s: Segment) throws {
        try dbq.write { try s.insert($0) }
    }

    func segments(forMeeting id: String) throws -> [Segment] {
        try dbq.read { db in
            try Segment
                .filter(Column("meeting_id") == id)
                .order(Column("start_ms"))
                .fetchAll(db)
        }
    }

    func resetStuckMeetings() throws {
        // Recovers from app crashes mid-recording.
        // - status=recording with no duration: the .mov was never finalised, so
        //   nothing useful to keep; drop the row + files.
        // - status=recording WITH a duration: capture finished but the status
        //   write never made it; flip to failed so the user can re-transcribe.
        //
        // Meetings stuck in status=transcribing are NOT touched here — the
        // caller (AppDelegate) reads them via `stuckTranscribingMeetingIds()`
        // and re-enqueues each one on launch. mic.wav/system.wav are still on
        // disk (we only delete them on archive), so resume is free.
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 1000
        try dbq.write { db in
            try db.execute(sql: """
                DELETE FROM meetings
                WHERE status = 'recording' AND duration_ms IS NULL AND started_at < ?
            """, arguments: [cutoff])
            try db.execute(sql: """
                UPDATE meetings SET status = 'failed'
                WHERE status = 'recording' AND started_at < ?
            """, arguments: [cutoff])
        }
    }

    /// IDs of meetings that were mid-transcription when the previous
    /// process died. Caller re-enqueues them via TranscriptionPipeline so
    /// the user never has to click "Re-transcribe" manually after a crash
    /// or a forced quit.
    func stuckTranscribingMeetingIds() throws -> [String] {
        try dbq.read { db in
            try Meeting
                .filter(Column("status") == "transcribing")
                .fetchAll(db)
                .map { $0.id }
        }
    }

    /// Rows still marked 'recording' — i.e. the process died mid-capture.
    /// `RecordingRecovery` inspects each one's audio on disk and either
    /// salvages it (→ transcribing) or leaves it for `resetStuckMeetings`
    /// to drop.
    func meetingsInRecordingState() throws -> [Meeting] {
        try dbq.read { db in
            try Meeting.filter(Column("status") == "recording").fetchAll(db)
        }
    }

    /// Ready, non-archived meetings that have a transcript but no title
    /// yet. Used by the launch backfill so recordings made before the
    /// auto-title feature get named without a full re-transcribe.
    func meetingIdsNeedingTitle() throws -> [String] {
        try dbq.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id FROM meetings m
                WHERE m.status = 'ready'
                  AND m.archived_at IS NULL
                  AND (m.title IS NULL OR TRIM(m.title) = '')
                  AND EXISTS (SELECT 1 FROM segments s WHERE s.meeting_id = m.id)
                ORDER BY m.started_at DESC
            """).map { $0["id"] ?? "" }.filter { !$0.isEmpty }
        }
    }

    /// One-time cleanup for "ghost" speakers — rows in the speakers table
    /// that have no segments referencing them. They came from the older
    /// dual-track code path that unconditionally inserted a "Speaker 1"
    /// row even when the mic was silent, and they skewed the clarify
    /// banner's "how many people were on the call?" default to one
    /// higher than the actual count. Gated to terminal-state meetings so
    /// we don't race a transcription that's between insertSpeaker() and
    /// insertSegment(). Returns the number of rows deleted.
    @discardableResult
    func purgeOrphanSpeakers() throws -> Int {
        try dbq.write { db in
            try db.execute(sql: """
                DELETE FROM speakers
                WHERE meeting_id IN (SELECT id FROM meetings WHERE status IN ('ready', 'archived'))
                  AND NOT EXISTS (
                    SELECT 1 FROM segments WHERE segments.speaker_id = speakers.id
                  )
            """)
            return db.changesCount
        }
    }

    func clearTranscript(meetingId: String) throws {
        try dbq.write { db in
            try db.execute(sql: "DELETE FROM segments WHERE meeting_id = ?", arguments: [meetingId])
            try db.execute(sql: "DELETE FROM speakers WHERE meeting_id = ?", arguments: [meetingId])
        }
    }

    func setSegmentBoost(segmentId: Int64, text: String?) throws {
        try dbq.write { db in
            try db.execute(sql: "UPDATE segments SET text_boost = ? WHERE id = ?",
                           arguments: [text, segmentId])
        }
    }

    /// Targeted UPDATE for the raw-turns cache. We must NOT use the full
    /// `updateMeeting(_:)` here — that would write every column from a
    /// stale local copy of the row, including `status`, which was just
    /// flipped to `.ready` inside mapTurnsToSpeakers. Round-tripping
    /// through `updateMeeting` would silently revert the row back to
    /// `.transcribing` and the next launch's resetStuckMeetings() would
    /// then mark it as `.failed`.
    func setRawTurnsCache(meetingId: String, geminiRawTurns: String?, audioHash: String?) throws {
        try dbq.write { db in
            try db.execute(sql: """
                UPDATE meetings
                SET gemini_raw_turns = ?,
                    audio_hash = ?
                WHERE id = ?
            """, arguments: [geminiRawTurns, audioHash, meetingId])
        }
    }

    /// Targeted title write — same reason as setRawTurnsCache: the
    /// pipeline's in-memory `meeting` copy can carry a stale status, so
    /// we never round-trip the whole row just to set the title.
    func setTitle(meetingId: String, title: String?) throws {
        try dbq.write { db in
            try db.execute(sql: "UPDATE meetings SET title = ? WHERE id = ?",
                           arguments: [title, meetingId])
        }
        if let m = try meeting(id: meetingId) {
            Task { @MainActor in SupabaseSync.upsertMeeting(m) }
        }
    }

    func setSummary(meetingId: String, summary: String?) throws {
        try dbq.write { db in
            try db.execute(sql: "UPDATE meetings SET summary = ? WHERE id = ?",
                           arguments: [summary, meetingId])
        }
        Task { @MainActor in SupabaseSync.setSummary(summary, meetingId: meetingId) }
    }

    /// Store the auto-generated Chapters JSON for a meeting. Setting
    /// `nil` clears the cached chapters so the pipeline's auto-step
    /// will regenerate on the next transcribe / re-transcribe.
    func setChapters(meetingId: String, chapters: String?) throws {
        try dbq.write { db in
            try db.execute(sql: "UPDATE meetings SET chapters = ? WHERE id = ?",
                           arguments: [chapters, meetingId])
        }
    }

    /// Flip ONLY the status column. Used on the transcribe failure path
    /// instead of `updateMeeting(meeting)`: the in-memory `meeting` copy is
    /// stale (e.g. it still carries the pre-increment `transcribe_attempts`),
    /// so writing the whole struct back would REVERT the attempt counter and
    /// defeat the launch/NetworkMonitor retry budget.
    func setStatus(meetingId: String, status: MeetingStatus) throws {
        try dbq.write { db in
            try db.execute(sql: "UPDATE meetings SET status = ? WHERE id = ?",
                           arguments: [status.rawValue, meetingId])
        }
    }

    /// Bump the consecutive-attempt counter at the start of a transcribe.
    func incrementTranscribeAttempts(meetingId: String) throws {
        try dbq.write { db in
            try db.execute(sql: "UPDATE meetings SET transcribe_attempts = transcribe_attempts + 1 WHERE id = ?",
                           arguments: [meetingId])
        }
    }

    /// Clear the attempt counter — called on a successful transcribe so a
    /// row that later fails gets its full retry budget again.
    func resetTranscribeAttempts(meetingId: String) throws {
        try dbq.write { db in
            try db.execute(sql: "UPDATE meetings SET transcribe_attempts = 0 WHERE id = ?",
                           arguments: [meetingId])
        }
    }

    /// IDs of `.failed` meetings still under the retry budget — the
    /// launch-time auto-retry re-enqueues these so a transient failure
    /// (network blip, killed mid-run) recovers without the user clicking
    /// Re-transcribe. `maxAttempts` bounds it so a permanently-broken row
    /// can't loop-fail (and re-bill) on every launch.
    func failedRetriableMeetingIds(maxAttempts: Int) throws -> [String] {
        try dbq.read { db in
            try Meeting
                .filter(Column("status") == "failed" && Column("transcribe_attempts") < maxAttempts)
                .fetchAll(db)
                .map { $0.id }
        }
    }

    func setDropboxArchive(meetingId: String, videoPath: String?, audioPath: String?, uploadedAt: Int64?) throws {
        try dbq.write { db in
            try db.execute(sql: """
                UPDATE meetings
                SET dropbox_video_path = ?,
                    dropbox_audio_path = ?,
                    dropbox_uploaded_at = ?
                WHERE id = ?
            """, arguments: [videoPath, audioPath, uploadedAt, meetingId])
        }
    }

    /// Bulk-delete segments by id. Used to retroactively scrub Whisper
    /// hallucinations from existing transcripts at app launch.
    func deleteSegments(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try dbq.write { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try db.execute(sql: "DELETE FROM segments WHERE id IN (\(placeholders))",
                           arguments: StatementArguments(ids))
        }
    }

    func allSegments() throws -> [Segment] {
        try dbq.read { db in
            try Segment.order(Column("start_ms")).fetchAll(db)
        }
    }

    func searchSegments(query: String) throws -> [Segment] {
        try dbq.read { db in
            try Segment.fetchAll(db, sql: """
                SELECT s.* FROM segments s
                JOIN segments_fts f ON f.rowid = s.id
                WHERE segments_fts MATCH ?
                ORDER BY rank
            """, arguments: [query])
        }
    }
}
