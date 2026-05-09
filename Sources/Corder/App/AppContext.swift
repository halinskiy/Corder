import Foundation
import Combine
import GRDB

@MainActor
final class AppContext: ObservableObject {
    static let shared = AppContext()
    private init() {}

    private(set) lazy var dbq: DatabaseQueue = {
        do { return try Database.openShared() }
        catch { fatalError("Failed to open DB: \(error)") }
    }()

    private(set) lazy var repo: MeetingRepository = MeetingRepository(dbq: dbq)
    let server = LocalServer()
    let capture = CaptureEngine()

    @Published var recordingState: RecordingState = .idle {
        didSet { RecordingStateSnapshot.update(recordingState) }
    }

    // Persisted source preference (Full screen vs last picked window stays remembered).
    @Published var sourceMode: SourceMode = SourceMode(
        rawValue: UserDefaults.standard.string(forKey: "Corder.sourceMode") ?? "full"
    ) ?? .full {
        didSet { UserDefaults.standard.set(sourceMode.rawValue, forKey: "Corder.sourceMode") }
    }

    /// Global "Boost" mode. When ON, every subsequent transcription is
    /// automatically polished via Gemini Flash after Whisper finishes — there's
    /// no per-meeting "Boost now" action. Persisted across launches.
    @Published var boostMode: Bool = UserDefaults.standard.bool(forKey: BoostMode.key) {
        didSet { UserDefaults.standard.set(boostMode, forKey: BoostMode.key) }
    }

    /// Interface language for the Library window AND the menu-bar popover.
    /// "ru" / "en". Defaults to "en".
    @Published var language: String = UserDefaults.standard.string(forKey: AppLanguage.key) ?? "en" {
        didSet { UserDefaults.standard.set(language, forKey: AppLanguage.key) }
    }
}

/// Thread-safe accessor for the persisted UI language.
enum AppLanguage {
    static let key = "Corder.language"
    static var current: String { UserDefaults.standard.string(forKey: key) ?? "en" }
}

/// Thread-safe accessor for the persisted boost flag, so non-MainActor code
/// (transcription pipeline detached tasks, request handlers) can read the
/// setting without hopping to MainActor. UserDefaults itself is thread-safe.
enum BoostMode {
    static let key = "Corder.boostMode"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }
}

enum SourceMode: String {
    case full   // full screen
    case window // pick a window each time
}

enum RecordingState: Equatable {
    case idle
    case recording(meetingId: String, startedAt: Date)
    case stopping
}

/// In-memory store for the last transcription error per meeting. Surfaces
/// quota / billing problems to the UI as a red toast without needing a DB
/// migration. Lock-protected so Swifter handlers (background threads) and
/// the @MainActor pipeline can both read/write safely.
enum TranscriptionErrors {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var byMeeting: [String: String] = [:]

    static func record(meetingId: String, message: String) {
        lock.lock(); defer { lock.unlock() }
        byMeeting[meetingId] = message
    }

    static func clear(meetingId: String) {
        lock.lock(); defer { lock.unlock() }
        byMeeting.removeValue(forKey: meetingId)
    }

    static func read(meetingId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return byMeeting[meetingId]
    }
}

/// Lock-protected mirror of `AppContext.shared.recordingState` so that
/// non-isolated code (e.g. Swifter request handlers running on background
/// threads) can read the current state without needing main-actor hops.
enum RecordingStateSnapshot {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: RecordingState = .idle

    static func update(_ state: RecordingState) {
        lock.lock(); defer { lock.unlock() }
        current = state
    }

    static func read() -> RecordingState {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}
