import Foundation
import CryptoKit

/// On-disk locations, ACCOUNT-SCOPED. Each signed-in Supabase user
/// (identified by email) gets their own folder under
/// `~/Library/Application Support/Corder/accounts/<email-hash>/`,
/// holding their corder.db + recordings/ + models/. Switching
/// Google accounts on the same Mac swaps to a different folder
/// — accounts can't see each other's recordings even at the
/// filesystem level.
///
/// While signed out we fall back to a `_guest` bucket so the lazy
/// `AppContext.repo` initialiser never has to swallow a `nil`.
/// The wizard gates the Library window the whole time, so the
/// guest bucket only sees empty reads.
///
/// Migration: on first sign-in under any account, the legacy
/// flat-layout `corder.db` at supportRoot is moved into that
/// account's folder. `migrateLegacyIfNeeded` is idempotent and
/// only fires when the destination is empty (so a second sign-in
/// under a different account doesn't steal the first user's
/// recordings).
enum AppPaths {
    /// Top-level Corder folder under Application Support.
    static var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Corder", isDirectory: true)
    }

    /// Container for per-account folders.
    static var accountsRoot: URL {
        supportRoot.appendingPathComponent("accounts", isDirectory: true)
    }

    /// 16-hex-char SHA-256 prefix of the lowercased+trimmed email
    /// — stable across cases / surrounding whitespace.
    static func accountID(forEmail email: String) -> String {
        let normalised = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalised.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// `nil` when signed out (the Library is closed in that state
    /// — only the lazy DB init might still touch `databaseURL`,
    /// hence the `_guest` fallback in `accountRoot` below).
    static func currentAccountID() -> String? {
        guard let email = AppSettings.userEmail else { return nil }
        return accountID(forEmail: email)
    }

    /// Active folder. `_guest` while signed out.
    static var accountRoot: URL {
        let id = currentAccountID() ?? "_guest"
        return accountsRoot.appendingPathComponent(id, isDirectory: true)
    }

    static var databaseURL: URL { accountRoot.appendingPathComponent("corder.db") }
    /// Disposable per-chunk transcript cache (own SQLite file so it never
    /// contends with the main DB's connection). Lets a transcribe that was
    /// killed mid-run resume from the chunks it already finished.
    static var chunkCacheURL: URL { accountRoot.appendingPathComponent("chunk_cache.db") }
    /// MACHINE-WIDE, NOT per-account. The on-device Whisper model is a PUBLIC
    /// artifact (not user data), so it lives once per Mac under `supportRoot`.
    /// Per-account storage meant a full ~1.5 GB RE-DOWNLOAD on every account
    /// folder switch — sign-in moved it into the account, then sign-out left the
    /// `_guest` folder empty and re-downloaded (observed: two 3 GB copies on
    /// disk). Sharing it kills that. The content-hashed ANE compile cache is
    /// unaffected (keyed by model content, not path). See `migrateModelToSharedIfNeeded`.
    static var modelsDir: URL { supportRoot.appendingPathComponent("models", isDirectory: true) }
    static var recordingsDir: URL { accountRoot.appendingPathComponent("recordings", isDirectory: true) }

    static func ensureExists() throws {
        for url in [supportRoot, accountsRoot, accountRoot, modelsDir, recordingsDir] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func recordingDir(for meetingId: String) -> URL {
        recordingsDir.appendingPathComponent(meetingId, isDirectory: true)
    }

    // MARK: - Legacy migration

    private static var legacyDatabaseURL: URL { supportRoot.appendingPathComponent("corder.db") }
    private static var legacyRecordingsDir: URL { supportRoot.appendingPathComponent("recordings", isDirectory: true) }
    private static var legacyModelsDir: URL { supportRoot.appendingPathComponent("models", isDirectory: true) }

    /// One-time move of the pre-multi-account flat layout into the
    /// account folder of the FIRST email that signs in on this
    /// install. Idempotent: does nothing once the account folder
    /// already has a `corder.db`, so a second sign-in under a
    /// different email doesn't clobber the first user's data.
    static func migrateLegacyIfNeeded(forEmail email: String) {
        let id = accountID(forEmail: email)
        let dst = accountsRoot.appendingPathComponent(id, isDirectory: true)
        let dstDB = dst.appendingPathComponent("corder.db")
        let fm = FileManager.default
        let legacyExists = fm.fileExists(atPath: legacyDatabaseURL.path)
        let dstHasDB = fm.fileExists(atPath: dstDB.path)
        guard legacyExists, !dstHasDB else { return }
        do {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            try fm.moveItem(at: legacyDatabaseURL, to: dstDB)
            // GRDB sidecars.
            for ext in ["-shm", "-wal"] {
                let src = supportRoot.appendingPathComponent("corder.db\(ext)")
                if fm.fileExists(atPath: src.path) {
                    try? fm.moveItem(at: src,
                                     to: dst.appendingPathComponent("corder.db\(ext)"))
                }
            }
            if fm.fileExists(atPath: legacyRecordingsDir.path) {
                try? fm.moveItem(at: legacyRecordingsDir,
                                 to: dst.appendingPathComponent("recordings", isDirectory: true))
            }
            if fm.fileExists(atPath: legacyModelsDir.path) {
                try? fm.moveItem(at: legacyModelsDir,
                                 to: dst.appendingPathComponent("models", isDirectory: true))
            }
            FileLogger.log("AppPaths: migrated legacy flat layout into accounts/\(id)/ for \(email)")
        } catch {
            FileLogger.log("AppPaths: legacy migration failed for \(email): \(error)")
        }
    }

    /// One-time move of the on-device model from the OLD per-account location
    /// (`accounts/<id>/models`) to the NEW machine-wide one (`supportRoot/models`),
    /// so existing installs don't re-download ~1.5 GB after the storage change.
    /// Moves the FIRST non-empty per-account model up, then deletes any remaining
    /// per-account model dirs (they were redundant duplicates — e.g. a `_guest`
    /// copy and an account copy after a sign-in/out cycle). Idempotent +
    /// best-effort: once `supportRoot/models` has a model it bails; a failure just
    /// means a re-download, never a crash. Runs at launch before any model load.
    static func migrateModelToSharedIfNeeded() {
        let fm = FileManager.default
        let shared = supportRoot.appendingPathComponent("models", isDirectory: true)
        func nonEmpty(_ url: URL) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == false)
        }
        // Already have a machine-wide model → nothing to move.
        guard !nonEmpty(shared) else { return }
        guard let accounts = try? fm.contentsOfDirectory(atPath: accountsRoot.path) else { return }
        // Move the first per-account model up to the shared location.
        for acc in accounts {
            let perAccount = accountsRoot.appendingPathComponent(acc, isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
            guard nonEmpty(perAccount) else { continue }
            do {
                try fm.createDirectory(at: supportRoot, withIntermediateDirectories: true)
                if fm.fileExists(atPath: shared.path) { try? fm.removeItem(at: shared) }
                try fm.moveItem(at: perAccount, to: shared)
                FileLogger.log("AppPaths: model storage now machine-wide — moved accounts/\(acc)/models → supportRoot/models")
                break
            } catch {
                FileLogger.log("AppPaths: shared-model migration move failed for \(acc): \(error)")
            }
        }
        // Reclaim any leftover per-account model copies (redundant now).
        if let accounts2 = try? fm.contentsOfDirectory(atPath: accountsRoot.path) {
            for acc in accounts2 {
                let perAccount = accountsRoot.appendingPathComponent(acc, isDirectory: true)
                    .appendingPathComponent("models", isDirectory: true)
                if fm.fileExists(atPath: perAccount.path) {
                    try? fm.removeItem(at: perAccount)
                    FileLogger.log("AppPaths: removed redundant per-account model copy accounts/\(acc)/models")
                }
            }
        }
    }
}
