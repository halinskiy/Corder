import Foundation
import GRDB

struct MeetingRepository {
    let dbq: DatabaseQueue

    func insertMeeting(_ m: Meeting) throws {
        try dbq.write { try m.insert($0) }
    }

    func updateMeeting(_ m: Meeting) throws {
        try dbq.write { try m.update($0) }
    }

    func deleteMeeting(id: String) throws {
        try dbq.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
        }
    }

    func meeting(id: String) throws -> Meeting? {
        try dbq.read { try Meeting.fetchOne($0, key: id) }
    }

    func listMeetings() throws -> [Meeting] {
        try dbq.read { db in
            try Meeting
                .filter(Column("archived_at") == nil)
                .order(Column("started_at").desc)
                .fetchAll(db)
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
        // Recovers from app crashes mid-recording or mid-transcribing.
        // - status=recording with no duration: the .mov was never finalised, so
        //   nothing useful to keep; drop the row + files.
        // - status=transcribing: keep the row and re-flag failed so the user can
        //   click Re-transcribe (the audio files are intact).
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 1000
        try dbq.write { db in
            try db.execute(sql: """
                DELETE FROM meetings
                WHERE status = 'recording' AND duration_ms IS NULL AND started_at < ?
            """, arguments: [cutoff])
            try db.execute(sql: """
                UPDATE meetings SET status = 'failed'
                WHERE status IN ('recording', 'transcribing') AND started_at < ?
            """, arguments: [cutoff])
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
