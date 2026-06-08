import Foundation
import GRDB

enum Database {
    static func openShared() throws -> DatabaseQueue {
        try AppPaths.ensureExists()
        let path = AppPaths.databaseURL.path
        do {
            let dbq = try DatabaseQueue(path: path)
            try Migrations.register().migrate(dbq)
            return dbq
        } catch {
            // Open or migration failed. The most common real-world cause is
            // a corrupt corder.db (a prior hard-kill mid-write) or a schema
            // that can't migrate on THIS user's machine. The previous code
            // let this throw straight into AppContext's `fatalError`, which
            // is exactly the "drag to Applications, double-click, NOTHING
            // happens" crash on other people's Macs. Instead: move the bad
            // file aside (NEVER delete — fully recoverable) and recreate a
            // fresh DB so the app actually OPENS. A signed-in user re-syncs
            // from the cloud; a brand-new user had no data to lose anyway.
            FileLogger.log("Database.openShared: open/migrate failed (\(error)) — quarantining DB + recreating")
            quarantineCorrupt(path: path)
            let dbq = try DatabaseQueue(path: path)
            try Migrations.register().migrate(dbq)
            return dbq
        }
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
