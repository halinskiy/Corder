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
    /// bucket is absent or empty (the common case after the first drain — the
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

        // (The on-device model is no longer migrated here — it's MACHINE-WIDE
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

            // Move each recording folder into the account FIRST so an inserted
            // row always points at an existing folder. Skip any that already
            // landed in the account (idempotent retry).
            for id in toMerge {
                let src = guestRecordings.appendingPathComponent(id, isDirectory: true)
                let dst = accountRecordings.appendingPathComponent(id, isDirectory: true)
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
                    // Drop the colliding INTEGER id — let SQLite assign a fresh
                    // rowid; the segments_ai trigger fills segments_fts.
                    try db.execute(sql: """
                        INSERT INTO segments (meeting_id, speaker_id, start_ms, end_ms, text, words_json)
                        SELECT meeting_id, speaker_id, start_ms, end_ms, text, words_json
                        FROM guestdb.segments WHERE meeting_id = ?
                        """, arguments: [id])
                }
            }

            FileLogger.log("GuestMigration: drained \(toMerge.count) guest meeting(s) into accounts/\(accountID)/ for \(email)")
            clearGuestData(fm: fm, guestDB: guestDB, guestRoot: guestRoot, guestRecordings: guestRecordings)
        } catch {
            FileLogger.log("GuestMigration: drain failed for \(email): \(error) — guest bucket left intact for retry")
        }
    }

    /// Remove the guest DB (+ WAL/SHM sidecars) and the now-emptied recordings
    /// dir. (The model is machine-wide now — not under `_guest` — so it's untouched.)
    private static func clearGuestData(fm: FileManager, guestDB: URL, guestRoot: URL, guestRecordings: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let p = guestDB.path + suffix
            if fm.fileExists(atPath: p) { try? fm.removeItem(atPath: p) }
        }
        // Drop whatever recording folders remain (merged ones were already
        // moved out; this clears empties + any left by a skipped/failed move).
        if fm.fileExists(atPath: guestRecordings.path) {
            try? fm.removeItem(at: guestRecordings)
        }
    }
}
