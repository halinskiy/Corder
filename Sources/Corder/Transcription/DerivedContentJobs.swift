import Foundation

/// One in-flight generation per (meeting, kind) for the derived text
/// passes (Summary, Chapters).
///
/// The pipeline fires the auto-summary the moment a row flips to `ready`,
/// and that is exactly when the user opens the Summary tab and sees the
/// "Generate" button (the recap is not there yet). Both callers used to run
/// their own Gemini call: two bills for one recap, and whichever finished
/// last silently overwrote the other. A second caller for the same key now
/// awaits the first call's result instead of starting its own.
actor DerivedContentJobs {
    static let shared = DerivedContentJobs()

    private var inflight: [String: Task<Any?, Error>] = [:]

    /// Runs `op` for `key`, or joins the run already in progress for it.
    /// `nil` from `op` (best-effort failure) is passed through unchanged.
    func run<T: Sendable>(_ key: String,
                          _ op: @escaping @Sendable () async throws -> T?) async throws -> T? {
        if let existing = inflight[key] {
            FileLogger.log("DerivedContentJobs: joining in-flight \(key)")
            return try await existing.value as? T
        }
        let task = Task<Any?, Error> { try await op() as Any? }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value as? T
    }
}
