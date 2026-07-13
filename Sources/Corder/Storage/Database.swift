import Foundation
import GRDB

enum Database {
    static func openShared() throws -> DatabaseQueue {
        try AppPaths.ensureExists()
        let path = AppPaths.databaseURL.path
        let migrator = Migrations.register()

        // First attempt, the happy path.
        do {
            let dbq = try DatabaseQueue(path: path)
            try migrator.migrate(dbq)
            return dbq
        } catch {
            FileLogger.log("Database.openShared: first open/migrate failed (\(error))")
        }

        // Distinguish the two failure classes, they need OPPOSITE handling:
        //
        //   • The file won't OPEN at all  → genuine corruption (hard-kill
        //     mid-write). Quarantine it aside (recoverable) + recreate fresh
        //     so the app launches instead of crashing. This is the real
        //     "drag to Applications, nothing happens" cause on users' Macs.
        //
        //   • The file opens but a MIGRATION throws → a deterministic schema
        //     bug. Recreating is POINTLESS (a fresh DB hits the same buggy
        //     migration) and HARMFUL (quarantine-loops every launch, spamming
        //     `.corrupt-*` files and wiping the user's data for a bug we'll
        //     fix in a patch). So: don't recreate, don't loop, let it fail
        //     once, visibly, with the data intact for the fixed build.
        let opensCleanly = (try? DatabaseQueue(path: path)) != nil

        if !opensCleanly {
            FileLogger.log("Database.openShared: DB is unreadable, quarantining + recreating fresh")
            quarantineCorrupt(path: path)
            // If the quarantine MOVE was denied (file locked by a still-dying
            // prior instance, permissions), the corrupt file is still there
            // remove it so the recreate doesn't just reopen the same bad file.
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
                try? fm.removeItem(atPath: path + suffix)
            }
            let dbq = try DatabaseQueue(path: path)
            try migrator.migrate(dbq)
            return dbq
        }

        // Opens cleanly → migration bug. Re-run migrate so the (rare,
        // deterministic, developer-side) error surfaces, but DON'T quarantine
        // or recreate, so the user's data survives until the fixed build.
        FileLogger.log("Database.openShared: DB opens but a migration fails, NOT recreating (data preserved)")
        let dbq = try DatabaseQueue(path: path)
        try migrator.migrate(dbq)
        return dbq
    }

    /// Rename `corder.db` (+ `-wal`/`-shm` sidecars) to a timestamped
    /// `.corrupt-<ts>` backup so a failed open never destroys data.
    private static func quarantineCorrupt(path: String) {
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let src = path + suffix
            guard fm.fileExists(atPath: src) else { continue }
            try? fm.moveItem(atPath: src, toPath: "\(path).corrupt-\(stamp)\(suffix)")
        }
    }
}
