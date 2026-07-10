import Foundation
import GRDB
import CryptoKit

/// Persistent, content-addressed cache of per-CHUNK transcription results
/// so a transcribe that's interrupted mid-run (app quit, crash, force
/// kill) resumes from the chunks it already finished instead of starting
/// over. The whole-meeting cache (`meetings.gemini_raw_turns`) only lands
/// at the very END of a successful run, so without this a long meeting
/// killed at chunk 9/10 redid all 10 chunks on the next attempt.
///
/// Keyed by `MD5(chunk audio)` (+ a provider/mode tag), NOT by meeting id
/// or position: the chunk slicing is deterministic, so the same source
/// audio re-slices to byte-identical chunks every run and the hashes line
/// up. Content addressing also means a chunk that didn't change is reused
/// even if earlier chunks shifted.
///
/// Lives in its OWN SQLite file (`AppPaths.chunkCacheURL`) so its writes
/// never contend with the main DB's connection. It's a disposable cache —
/// entries self-expire after `ttlDays`; losing it just means a re-run
/// re-transcribes, never a correctness problem.
enum ChunkTranscriptCache {
    private static let ttlDays = 7
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _dbq: DatabaseQueue?
    nonisolated(unsafe) private static var _dbqPath: String?

    /// Lazily-opened queue, re-opened if the account folder (and thus the
    /// path) changed under us. Thread-safe: callers run on the background
    /// transcription threads.
    private static func dbq() -> DatabaseQueue? {
        lock.lock(); defer { lock.unlock() }
        let path = AppPaths.chunkCacheURL.path
        if let q = _dbq, _dbqPath == path { return q }
        try? AppPaths.ensureExists()
        guard let q = try? DatabaseQueue(path: path) else { return nil }
        do {
            try q.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS chunk_cache (
                        cache_key  TEXT PRIMARY KEY NOT NULL,
                        turns_json TEXT NOT NULL,
                        created_at INTEGER NOT NULL,
                        language   TEXT NOT NULL DEFAULT ''
                    );
                """)
                // Older cache files predate the `language` column; add it so
                // a resumed chunk can still feed the language-drift tally.
                // Ignore the error when it already exists.
                try? db.execute(sql: "ALTER TABLE chunk_cache ADD COLUMN language TEXT NOT NULL DEFAULT ''")
                // Drop stale entries opportunistically on open — cheap,
                // and keeps the file from growing unbounded.
                let cutoff = Int(Date().timeIntervalSince1970) - ttlDays * 86_400
                try db.execute(sql: "DELETE FROM chunk_cache WHERE created_at < ?", arguments: [cutoff])
            }
        } catch {
            FileLogger.log("ChunkTranscriptCache: open/migrate failed — \(error)")
            return nil
        }
        _dbq = q
        _dbqPath = path
        return q
    }

    /// Stable key for one chunk. `tag` distinguishes provider/mode so a
    /// re-transcribe with a different provider doesn't replay another
    /// model's text. `chunkURL` is the sliced WAV on disk.
    static func key(forChunkAt chunkURL: URL, tag: String) -> String? {
        guard let md5 = try? md5OfFile(at: chunkURL) else { return nil }
        return "\(tag):\(md5)"
    }

    /// Cached chunk result plus the language Whisper detected for it (empty
    /// string for entries written before the column existed).
    static func get(_ key: String) -> (turns: [GeminiTranscriber.Turn], language: String)? {
        guard let q = dbq() else { return nil }
        let row: Row?? = try? q.read { db in
            try Row.fetchOne(db, sql: "SELECT turns_json, language FROM chunk_cache WHERE cache_key = ?", arguments: [key])
        }
        guard let inner = row, let r = inner,
              let j: String = r["turns_json"], let data = j.data(using: .utf8),
              let turns = try? JSONDecoder().decode([GeminiTranscriber.Turn].self, from: data) else { return nil }
        let language: String = r["language"] ?? ""
        return (turns, language)
    }

    static func put(_ key: String, _ turns: [GeminiTranscriber.Turn], language: String) {
        guard let q = dbq(),
              let data = try? JSONEncoder().encode(turns),
              let json = String(data: data, encoding: .utf8) else { return }
        let now = Int(Date().timeIntervalSince1970)
        try? q.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO chunk_cache (cache_key, turns_json, created_at, language) VALUES (?, ?, ?, ?)",
                arguments: [key, json, now, language])
        }
    }

    // MARK: - Helpers

    private static func md5OfFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while autoreleasepool(invoking: { () -> Bool in
            let chunk = handle.readData(ofLength: 1 << 20)  // 1 MB
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
