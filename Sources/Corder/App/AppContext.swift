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

    /// Sparkle-reported version string of the newest pending update,
    /// e.g. "0.8.0". `nil` means no update is available right now. The
    /// React toolbar polls `/api/update-status` and renders a green
    /// pill linking to `POST /api/check-update` when this is set.
    @Published var availableUpdateVersion: String? = nil {
        didSet { AvailableUpdateSnapshot.update(availableUpdateVersion) }
    }

    // Persisted source preference (Full screen vs last picked window stays remembered).
    @Published var sourceMode: SourceMode = SourceMode(
        rawValue: UserDefaults.standard.string(forKey: "Corder.sourceMode") ?? "full"
    ) ?? .full {
        didSet { UserDefaults.standard.set(sourceMode.rawValue, forKey: "Corder.sourceMode") }
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

/// Thread-safe accessor for the user's custom vocabulary (domain terms).
/// Read from the transcription pipeline (non-MainActor) to bias Gemini
/// toward correct spellings of names / jargon / acronyms.
enum AppVocabulary {
    static let key = "Corder.vocabulary"
    static var current: String {
        (UserDefaults.standard.string(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Persisted user settings — same synchronous, thread-safe
/// `UserDefaults` source-of-truth pattern as `AppLanguage` /
/// `AppVocabulary`. Read off-main from the capture queues, the
/// pipeline and `MeetingDetector`; written through `POST /api/settings`.
/// Every Bool defaults to `true` so a fresh install — or an older
/// client that never sends the key — keeps today's "everything on"
/// behaviour (UserDefaults.bool would wrongly report `false` for an
/// absent key, hence the explicit object(forKey:) nil check).
enum AppSettings {
    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? true
            : UserDefaults.standard.bool(forKey: key)
    }
    private static func setFlag(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
    private static func int(_ key: String, _ def: Int) -> Int {
        UserDefaults.standard.object(forKey: key) == nil
            ? def
            : UserDefaults.standard.integer(forKey: key)
    }
    private static func setInt(_ key: String, _ value: Int) {
        UserDefaults.standard.set(value, forKey: key)
    }
    private static func list(_ key: String) -> [String] {
        guard let data = UserDefaults.standard.string(forKey: key)?.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return arr
    }
    private static func setList(_ key: String, _ value: [String]) {
        let cleaned = value
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let data = try? JSONEncoder().encode(cleaned),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: key)
        }
    }

    private static let kNotifications  = "Corder.set.notifications"
    private static let kCaptureVideo   = "Corder.set.captureVideo"
    private static let kCaptureAudio   = "Corder.set.captureAudio"
    private static let kAutoTranscribe = "Corder.set.autoTranscribe"
    private static let kAutoTitle      = "Corder.set.autoTitle"
    private static let kWhitelist      = "Corder.set.meetingWhitelist"
    private static let kBlacklist      = "Corder.set.meetingBlacklist"

    static var notificationsEnabled: Bool { flag(kNotifications) }
    static var captureVideo: Bool          { flag(kCaptureVideo) }
    static var captureAudio: Bool          { flag(kCaptureAudio) }
    static var autoTranscribe: Bool        { flag(kAutoTranscribe) }
    static var autoTitle: Bool             { flag(kAutoTitle) }
    static var meetingWhitelist: [String]  { list(kWhitelist) }
    static var meetingBlacklist: [String]  { list(kBlacklist) }

    static func setNotifications(_ v: Bool)  { setFlag(kNotifications, v) }
    static func setCaptureVideo(_ v: Bool)   { setFlag(kCaptureVideo, v) }
    static func setCaptureAudio(_ v: Bool)   { setFlag(kCaptureAudio, v) }
    static func setAutoTranscribe(_ v: Bool) { setFlag(kAutoTranscribe, v) }
    static func setAutoTitle(_ v: Bool)      { setFlag(kAutoTitle, v) }
    static func setMeetingWhitelist(_ v: [String]) { setList(kWhitelist, v) }
    static func setMeetingBlacklist(_ v: [String]) { setList(kBlacklist, v) }

    // Global record hotkey. Stored as a Carbon virtual key code + a
    // Carbon modifier mask (cmdKey 256 | shiftKey 512 | optionKey 2048 |
    // controlKey 4096). Default = ⌘⇧F (kVK_ANSI_F = 3, cmd|shift = 768)
    // — not a stock macOS system shortcut, so it's a safe default.
    private static let kRecCode = "Corder.set.recHotkeyCode"
    private static let kRecMods = "Corder.set.recHotkeyMods"
    static var recordHotkeyKeyCode: Int  { int(kRecCode, 3) }
    static var recordHotkeyModifiers: Int { int(kRecMods, 768) }
    static func setRecordHotkey(code: Int, mods: Int) {
        setInt(kRecCode, code); setInt(kRecMods, mods)
    }
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

/// Same pattern as `RecordingStateSnapshot` for the Sparkle-reported
/// "newer version available" flag — Swifter handlers run off-actor and
/// need a synchronous read without hopping to `@MainActor`.
enum AvailableUpdateSnapshot {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: String? = nil

    static func update(_ version: String?) {
        lock.lock(); defer { lock.unlock() }
        current = version
    }

    static func read() -> String? {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}

/// Bundle ids that have recently been seen owning the microphone,
/// surfaced read-only to the Settings UI so the user can add an app to
/// the white/blacklist by tapping it instead of typing a bundle id.
/// Populated by `MeetingDetector` each tick; read by the Swifter
/// `/api/settings` handler (off-actor), hence the lock mirror.
enum MicAppsSnapshot {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recent: [String] = []

    static func update(_ bundles: [String]) {
        lock.lock(); defer { lock.unlock() }
        var seen = Set(recent)
        for b in bundles where !b.isEmpty && !seen.contains(b) {
            recent.append(b); seen.insert(b)
        }
        if recent.count > 40 { recent.removeFirst(recent.count - 40) }
    }

    static func read() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return recent
    }
}

/// Whether the last global-hotkey registration actually succeeded
/// (Carbon `RegisterEventHotKey` returned noErr). Surfaced read-only to
/// the Settings UI so it can warn "couldn't bind — another app may
/// already use this combo". Lock mirror: written on the main actor by
/// `HotkeyManager`, read off-actor by the Swifter `/api/settings`.
enum HotkeyStatusSnapshot {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ok = true
    static func update(_ v: Bool) { lock.lock(); defer { lock.unlock() }; ok = v }
    static func read() -> Bool { lock.lock(); defer { lock.unlock() }; return ok }
}
