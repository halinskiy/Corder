import Foundation
import GRDB

/// Drains the signed-out `_guest` bucket into the signed-in account on
/// sign-in, so recordings made before logging in "follow" the user into
/// their account instead of being stranded (invisible) in `_guest`.
///
/// Scenario this fixes: a user with an account is signed OUT, records a few
/// calls (they land in `accounts/_guest/`), THEN signs in via Google. Before
/// this, `currentAccountID()` flipped to the email-hash folder and the guest
/// recordings vanished from view (they were never deleted, just never shown).
/// Now they're MERGED into the account on the next launch.
///
/// Design notes:
///  • MERGE, not move: the account may already have its own recordings, so we
///    copy rows in rather than clobbering the destination DB.
///  • Idempotent by meeting UUID: only meetings NOT already in the account are
///    merged, so a partial failure that leaves `_guest` intact re-runs cleanly
///    next launch without duplicating anything.
///  • `segments.id` is an autoincrement INTEGER that COLLIDES between the two
///    DBs (both start at 1), so segments are re-inserted WITHOUT their id (a
///    fresh rowid is assigned). The `segments_ai` AFTER INSERT trigger keeps
///    the `segments_fts` search index in sync automatically. `meetings.id` /
///    `speakers.id` are TEXT UUIDs (no collision) → plain INSERT OR IGNORE.
///  • Defensive: never throws up to the caller. On any failure the guest bucket
///    is left intact for a retry; the worst case is the pre-existing behaviour
///    (recordings stay in `_guest`), never a crash or data loss.
///  • Runs in `applicationDidFinishLaunching`, BEFORE the account DB's shared
///    connection opens, alongside `AppPaths.migrateLegacyIfNeeded`.
enum GuestMigration {
    private static let mergedTables = ["meetings", "speakers", "segments"]

    /// Drain `_guest` into the account folder for `email`. No-op when the guest
    /// bucket is absent or empty (the common case after the first drain, the
    /// guest DB is deleted on success, so steady-state launches pay one
    /// `fileExists` check).
    static func drainIntoAccount(forEmail email: String) {
        let fm = FileManager.default
        let accountID = AppPaths.accountID(forEmail: email)
        // Never drain the guest bucket into itself.
        guard accountID != "_guest" else { return }

        let accountsRoot = AppPaths.accountsRoot
        let guestRoot = accountsRoot.appendingPathComponent("_guest", isDirectory: true)
        let accountRoot = accountsRoot.appendingPathComponent(accountID, isDirectory: true)

        // (The on-device model is no longer migrated here, it's MACHINE-WIDE
        // now, `supportRoot/models`, shared across guest + every account, so a
        // sign-in/out never re-downloads it. See AppPaths.migrateModelToSharedIfNeeded.)
        let guestDB = guestRoot.appendingPathComponent("corder.db")
        guard fm.fileExists(atPath: guestDB.path) else { return }

        let accountDB = accountRoot.appendingPathComponent("corder.db")
        let guestRecordings = guestRoot.appendingPathComponent("recordings", isDirectory: true)
        let accountRecordings = accountRoot.appendingPathComponent("recordings", isDirectory: true)

        do {
            try fm.createDirectory(at: accountRecordings, withIntermediateDirectories: true)
            let migrator = Migrations.register()

            // Open + migrate BOTH DBs to the CURRENT schema so a cross-DB
            // INSERT…SELECT lines columns up regardless of which app version
            // wrote the guest bucket. (A guest DB written by an older build is
            // brought up to date here before we read it.)
            let guestQ = try DatabaseQueue(path: guestDB.path)
            try migrator.migrate(guestQ)
            let guestMeetingIDs: [String] = try guestQ.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM meetings")
            }
            guard !guestMeetingIDs.isEmpty else {
                // Empty guest bucket: drop the stray DB so we don't re-scan it
                // every launch, but keep `_guest/models/` (a cached on-device
                // model the next signed-out session can reuse).
                clearGuestData(fm: fm, guestDB: guestDB, guestRoot: guestRoot, guestRecordings: guestRecordings)
                return
            }

            let accountQ = try DatabaseQueue(path: accountDB.path)
            try migrator.migrate(accountQ)
            let existing: Set<String> = try accountQ.read { db in
                Set(try String.fetchAll(db, sql: "SELECT id FROM meetings"))
            }
            let toMerge = guestMeetingIDs.filter { !existing.contains($0) }
            guard !toMerge.isEmpty else {
                // Everything already merged (a prior run got the rows in but
                // didn't get to clear `_guest`). Finish the cleanup now.
                clearGuestData(fm: fm, guestDB: guestDB, guestRoot: guestRoot, guestRecordings: guestRecordings)
                return
            }

            // The recording FOLDER name is `meetings.dir_name` ("<date> <title>",
            // 0.15.29), NOT the bare `<id>`. Moving by `<id>` silently found
            // nothing (the folder is named `<date> <title>`), so the audio never
            // moved and `clearGuestData` then hard-DELETED it, the sign-in
            // data-loss bug. Move by dir_name; fall back to `<id>` for legacy
            // folders that were never renamed.
            let guestDirNames: [String: String] = (try? guestQ.read { db -> [String: String] in
                var m: [String: String] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT id, dir_name FROM meetings WHERE dir_name IS NOT NULL") {
                    if let mid: String = row["id"], let n: String = row["dir_name"] { m[mid] = n }
                }
                return m
            }) ?? [:]
            // Move each recording folder into the account FIRST so an inserted
            // row always points at an existing folder. Skip any that already
            // landed in the account (idempotent retry).
            for id in toMerge {
                let folder = guestDirNames[id] ?? id
                let src = guestRecordings.appendingPathComponent(folder, isDirectory: true)
                let dst = accountRecordings.appendingPathComponent(folder, isDirectory: true)
                guard fm.fileExists(atPath: src.path) else { continue }
                if fm.fileExists(atPath: dst.path) { continue }
                try? fm.moveItem(at: src, to: dst)
            }

            // Copy the rows for the new meetings. ATTACH the guest DB and insert
            // per meeting so a single bad row never aborts the whole drain.
            try accountQ.write { db in
                let quoted = guestDB.path.replacingOccurrences(of: "'", with: "''")
                try db.execute(sql: "ATTACH DATABASE '\(quoted)' AS guestdb")
                defer { try? db.execute(sql: "DETACH DATABASE guestdb") }
                for id in toMerge {
                    try db.execute(sql: "INSERT OR IGNORE INTO meetings SELECT * FROM guestdb.meetings WHERE id = ?",
                                   arguments: [id])
                    try db.execute(sql: "INSERT OR IGNORE INTO speakers SELECT * FROM guestdb.speakers WHERE meeting_id = ?",
                                   arguments: [id])
                    // Drop the colliding INTEGER id, let SQLite assign a fresh
                    // rowid; the segments_ai trigger fills segments_fts.
                    try db.execute(sql: """
                        INSERT INTO segments (meeting_id, speaker_id, start_ms, end_ms, text, words_json)
                        SELECT meeting_id, speaker_id, start_ms, end_ms, text, words_json
                        FROM guestdb.segments WHERE meeting_id = ?
                        """, arguments: [id])
                }
            }

            // Re-base the stored absolute video/audio paths onto the account
            // folder, they were copied verbatim still pointing at
            // `_guest/recordings/...`, so playback/transcription would 404. The
            // folder NAME is unchanged (moved by dir_name above), so a plain
            // prefix swap of the recordings root is exact.
            try accountQ.write { db in
                for id in toMerge {
                    try db.execute(sql: """
                        UPDATE meetings
                        SET video_path = REPLACE(video_path, ?, ?),
                            audio_path = REPLACE(audio_path, ?, ?)
                        WHERE id = ?
                        """, arguments: [guestRecordings.path, accountRecordings.path,
                                         guestRecordings.path, accountRecordings.path, id])
                }
            }

            FileLogger.log("GuestMigration: drained \(toMerge.count) guest meeting(s) into accounts/\(accountID)/ for \(email)")
            clearGuestData(fm: fm, guestDB: guestDB, guestRoot: guestRoot, guestRecordings: guestRecordings)
        } catch {
            FileLogger.log("GuestMigration: drain failed for \(email): \(error), guest bucket left intact for retry")
        }
    }

    /// Clear the guest bucket AFTER a successful drain, but SAFELY. The old
    /// version force-removed the whole recordings dir, which is exactly how a
    /// folder that failed to move (or was looked up by the wrong name) got its
    /// audio hard-DELETED. Now: if ANY recording folder is still present, DELETE
    /// NOTHING (leave the DB + audio intact for a retry / manual recovery); only
    /// when the recordings dir is empty (everything moved) do we clear the stray
    /// guest DB + the empty dir.
    private static func clearGuestData(fm: FileManager, guestDB: URL, guestRoot: URL, guestRecordings: URL) {
        if fm.fileExists(atPath: guestRecordings.path) {
            let remaining = ((try? fm.contentsOfDirectory(atPath: guestRecordings.path)) ?? [])
                .filter { $0 != ".DS_Store" }
            if !remaining.isEmpty {
                FileLogger.log("GuestMigration: \(remaining.count) guest recording folder(s) still present, NOT deleting anything (audio kept for recovery)")
                return
            }
            try? fm.removeItem(at: guestRecordings)
        }
        for suffix in ["", "-wal", "-shm"] {
            let p = guestDB.path + suffix
            if fm.fileExists(atPath: p) { try? fm.removeItem(atPath: p) }
        }
    }
}
