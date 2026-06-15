import Foundation
import Combine
import GRDB
import ServiceManagement

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
    private static let kAutoSummary    = "Corder.set.autoSummary"
    private static let kAutoChapters   = "Corder.set.autoChapters"
    private static let kTelemetry      = "Corder.set.telemetry"
    private static let kStatsEnabled   = "Corder.set.statsEnabled"
    private static let kPrerollEnabled = "Corder.set.prerollEnabled"
    private static let kWhitelist      = "Corder.set.meetingWhitelist"
    private static let kBlacklist      = "Corder.set.meetingBlacklist"
    private static let kTranscriptionProvider = "Corder.set.transcriptionProvider"
    private static let kWhisperLocalVariant   = "Corder.set.whisperLocalVariant"
    /// Persistent upsell-dismiss timestamps. JSON-encoded map keyed by
    /// upsell kind (`speed` / `best` / `unlimited`). Lives in
    /// UserDefaults instead of WKWebView localStorage because the
    /// embedded server's port can rotate between launches, which wipes
    /// any per-origin web storage.
    private static let kUpsellSnooze          = "Corder.set.upsellSnooze"
    private static let kTranscriptCleanup = "Corder.set.transcriptCleanup"
    /// Sticky permission grants. `CGPreflightScreenCaptureAccess()`
    /// returns false right after a re-install of a previously-
    /// authorised app — the OS keeps the TCC grant against the
    /// bundle id but `preflight` is process-cached and reports
    /// false until the first live screen-capture call. We snapshot
    /// the grant state to UserDefaults the first time we observe
    /// `granted` for either permission, and trust that snapshot
    /// across sign-outs / re-installs. Cleared only if the user
    /// explicitly revokes in System Settings (we then re-detect
    /// `denied` and clear the flag).
    private static let kMicGrantedOnce  = "Corder.perm.micGrantedOnce"
    private static let kScreenGrantedOnce = "Corder.perm.screenGrantedOnce"
    static var micGrantedSticky: Bool { UserDefaults.standard.bool(forKey: kMicGrantedOnce) }
    static var screenGrantedSticky: Bool { UserDefaults.standard.bool(forKey: kScreenGrantedOnce) }
    static func setMicGrantedSticky(_ v: Bool) { UserDefaults.standard.set(v, forKey: kMicGrantedOnce) }
    static func setScreenGrantedSticky(_ v: Bool) { UserDefaults.standard.set(v, forKey: kScreenGrantedOnce) }

    static var notificationsEnabled: Bool { flag(kNotifications) }
    static var captureVideo: Bool          { flag(kCaptureVideo) }
    static var captureAudio: Bool          { flag(kCaptureAudio) }
    static var autoTranscribe: Bool        { flag(kAutoTranscribe) }
    static var autoTitle: Bool             { flag(kAutoTitle) }
    static var autoSummary: Bool           { flag(kAutoSummary) }
    static var autoChapters: Bool          { flag(kAutoChapters) }
    /// Diagnostic telemetry. Default OFF — opt-in only. The paid plans
    /// have shipped and the landing promises "No telemetry, no analytics,
    /// no pings" inside the app, so the default MUST stay off to keep that
    /// claim true. A user who explicitly enables it sends aggregate signal
    /// only: no transcripts, no raw email; everything through
    /// `TelemetryService` is aggregate + a SHA-256 anonymous id.
    static var telemetryEnabled: Bool {
        UserDefaults.standard.object(forKey: kTelemetry) as? Bool ?? false
    }
    /// Dashboard statistics block. Default OFF for everyone; the toggle
    /// that enables it lives in Advanced and is shown only to paid tiers
    /// (web SettingsPane). Opt-in, so an absent key ≡ off.
    static var statsEnabled: Bool {
        UserDefaults.standard.object(forKey: kStatsEnabled) as? Bool ?? false
    }
    /// Silent pre-roll: start capturing the instant a call is detected so
    /// that accepting the "record this call?" offer keeps the audio/video
    /// from the very start. Default OFF — it records (and then discards on
    /// decline) before the user consents, so it must be an explicit opt-in.
    static var prerollEnabled: Bool {
        UserDefaults.standard.object(forKey: kPrerollEnabled) as? Bool ?? false
    }
    static var meetingWhitelist: [String]  { list(kWhitelist) }
    static var meetingBlacklist: [String]  { list(kBlacklist) }

    /// Launch Corder when the Mac boots / the user logs in. Source of
    /// truth is the live `SMAppService.mainApp` registration status
    /// (macOS 13+); the UserDefaults key is only a cached mirror for
    /// fast reads when building the settings DTO. Defaults OFF — a
    /// fresh install must not silently add itself to login items.
    private static let kLaunchAtLogin = "Corder.set.launchAtLogin"
    static var launchAtLogin: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return UserDefaults.standard.bool(forKey: kLaunchAtLogin)
    }
    static func setLaunchAtLogin(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: kLaunchAtLogin)
        if #available(macOS 13.0, *) {
            do {
                if v {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                FileLogger.log("launchAtLogin: \(v ? "register" : "unregister") failed: \(error)")
            }
        }
    }

    static func setNotifications(_ v: Bool)  { setFlag(kNotifications, v) }
    static func setCaptureVideo(_ v: Bool)   { setFlag(kCaptureVideo, v) }
    static func setCaptureAudio(_ v: Bool)   { setFlag(kCaptureAudio, v) }
    static func setAutoTranscribe(_ v: Bool) { setFlag(kAutoTranscribe, v) }
    static func setAutoTitle(_ v: Bool)      { setFlag(kAutoTitle, v) }
    static func setAutoSummary(_ v: Bool)    { setFlag(kAutoSummary, v) }
    static func setAutoChapters(_ v: Bool)   { setFlag(kAutoChapters, v) }
    static func setTelemetryEnabled(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: kTelemetry)
    }
    static func setStatsEnabled(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: kStatsEnabled)
    }
    static func setPrerollEnabled(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: kPrerollEnabled)
    }
    static func setMeetingWhitelist(_ v: [String]) { setList(kWhitelist, v) }
    static func setMeetingBlacklist(_ v: [String]) { setList(kBlacklist, v) }

    /// ASR provider toggle (Gemini default, OpenAI Whisper as opt-in).
    /// Default is `.gemini` so existing users keep their pipeline
    /// untouched on upgrade; the Settings UI toggle is wired separately.
    /// ASR provider is tier-driven, not user-selectable. Each tier
    /// maps to the right cost/quality trade-off:
    ///   • Free → `.whisperLocal` (on-device, $0/час forever)
    ///   • Pro  → `.whisper`      (cloud whisper-1 + gpt-4o-mini polish, ~$0.36/час)
    ///   • Max  → `.whisper`      (same as Pro for now; reserved for future
    ///                             upgrade to Gemini Pro / o-series when
    ///                             tier-specific premium model is wired)
    ///
    /// The raw `kTranscriptionProvider` UserDefaults key is still
    /// honoured as an EXPLICIT OVERRIDE for dev / QA. If somebody runs
    /// `defaults write com.3mpq.Corder Corder.set.transcriptionProvider whisper`,
    /// we respect it regardless of tier. Cleared via setting empty
    /// string or removing the key. End users should NEVER hit this
    /// path through the UI.
    ///
    /// Cache keys are prefixed with the provider name so the three
    /// providers' raw outputs never replay each other.
    static var transcriptionProvider: TranscriptionProvider {
        // Explicit override wins — except for legacy `gemini`, which
        // we no longer offer in the picker (Whisper Cloud is the
        // single cloud option). A stale `gemini` override coerces
        // back to the tier default so an old account doesn't keep
        // routing through a provider we don't surface anymore.
        if let raw = UserDefaults.standard.string(forKey: kTranscriptionProvider),
           let p = TranscriptionProvider(rawValue: raw),
           p != .gemini {
            return p
        }
        // Tier-driven default.
        switch userTier {
        case .free:           return .whisperLocal
        case .pro, .max:      return .whisper
        }
    }
    static func setTranscriptionProvider(_ v: TranscriptionProvider) {
        UserDefaults.standard.set(v.rawValue, forKey: kTranscriptionProvider)
    }
    /// Clear the dev override so the tier-driven default is in effect
    /// again. UI doesn't surface this; ops / support flow only.
    static func clearTranscriptionProviderOverride() {
        UserDefaults.standard.removeObject(forKey: kTranscriptionProvider)
    }

    /// Active variant of the on-device Whisper Core ML model. The user
    /// picks size vs accuracy in Settings (Tiny / Base / Small / Turbo);
    /// the pipeline reads this when `transcriptionProvider == .whisperLocal`
    /// and lazily downloads on first use if the picked variant isn't
    /// already on disk. Default = `.turbo` to keep existing meetings
    /// behaving exactly as before the multi-variant change.
    static var whisperLocalVariant: LocalWhisperTranscriber.Variant {
        if let raw = UserDefaults.standard.string(forKey: kWhisperLocalVariant),
           let v = LocalWhisperTranscriber.Variant(rawValue: raw) {
            return v
        }
        return LocalWhisperTranscriber.defaultVariant
    }
    static func setWhisperLocalVariant(_ v: LocalWhisperTranscriber.Variant) {
        UserDefaults.standard.set(v.rawValue, forKey: kWhisperLocalVariant)
    }

    /// Forced transcription language (ISO-639-1, e.g. "ru"). Empty =
    /// auto-detect. Whisper (cloud + local) otherwise guesses the
    /// language per recording and, for Russian audio, frequently drifts
    /// to the very-close Ukrainian — rendering Russian speech as
    /// Ukrainian words. Pinning the language stops that. Gemini already
    /// preserves the spoken language verbatim, so this only feeds the
    /// Whisper paths.
    private static let kTranscriptionLanguage = "Corder.set.transcriptionLanguage"
    static var transcriptionLanguage: String {
        (UserDefaults.standard.string(forKey: kTranscriptionLanguage) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func setTranscriptionLanguage(_ v: String) {
        let cleaned = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.isEmpty {
            UserDefaults.standard.removeObject(forKey: kTranscriptionLanguage)
        } else {
            UserDefaults.standard.set(cleaned, forKey: kTranscriptionLanguage)
        }
    }

    static var upsellSnooze: String {
        UserDefaults.standard.string(forKey: kUpsellSnooze) ?? ""
    }
    static func setUpsellSnooze(_ json: String) {
        if json.isEmpty {
            UserDefaults.standard.removeObject(forKey: kUpsellSnooze)
        } else {
            UserDefaults.standard.set(json, forKey: kUpsellSnooze)
        }
    }

    /// LLM polish toggle for Whisper transcripts. When ON (default for
    /// Whisper users), raw whisper-1 output goes through gpt-4o-mini for
    /// punctuation / capitalisation / obvious-typo cleanup before being
    /// persisted. Best-effort: any failure falls back to the raw turns
    /// untouched, so flipping this flag never breaks transcription —
    /// only the polish stage is gated. Gemini path ignores this setting.
    static var transcriptCleanup: Bool { flag(kTranscriptCleanup) }
    static func setTranscriptCleanup(_ v: Bool) { setFlag(kTranscriptCleanup, v) }

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

    // Preferred microphone input device, stored as the Core Audio
    // device UID (stable across reboots, unlike the numeric AudioDeviceID
    // which the system re-issues). `nil` (key absent / empty string)
    // means "use whatever the system currently calls default input" —
    // identical to the pre-feature behaviour and the fallback when the
    // saved device is unplugged at recording start. We persist the UID
    // (not the human name) because device names can collide
    // ("USB Audio Device", "External Microphone") while UIDs don't.
    private static let kMicDeviceUID = "Corder.set.micDeviceUID"
    static var micDeviceUID: String? {
        let raw = (UserDefaults.standard.string(forKey: kMicDeviceUID) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
    static func setMicDeviceUID(_ uid: String?) {
        let cleaned = (uid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            UserDefaults.standard.removeObject(forKey: kMicDeviceUID)
        } else {
            UserDefaults.standard.set(cleaned, forKey: kMicDeviceUID)
        }
    }

    // Paddle-issued licence key the user pastes into the Welcome wizard
    // (or, later, Settings). MVP rule: any non-empty, well-formed key
    // — ≥ 20 chars, alphanumeric / dash / underscore — flips the local
    // `isPro` switch. Real server-side validation lands when we have a
    // backend; until then the honour system is enough (the free tier
    // already covers the unconverted-user case, and cheaters are not
    // the bottleneck on day one). Cleared by setting an empty string.
    private static let kLicenceKey = "Corder.set.licenceKey"
    static var licenceKey: String? {
        let raw = (UserDefaults.standard.string(forKey: kLicenceKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
    static func setLicenceKey(_ key: String?) {
        let cleaned = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            UserDefaults.standard.removeObject(forKey: kLicenceKey)
        } else {
            UserDefaults.standard.set(cleaned, forKey: kLicenceKey)
        }
    }
    /// Format-only validation. We can't reach the server yet, so any
    /// reasonably licence-shaped string (≥ 20 chars, A-Z/0-9/-/_)
    /// passes. The point is to catch obvious typos (single letter,
    /// trailing space, accidental email), not to defeat a determined
    /// attacker. Real cryptographic checks land with the backend.
    static func isValidLicenceFormat(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
    // Three-tier model (Free / Pro / Max). Stored as the raw string so
    // a future fourth tier slots in without a UserDefaults migration.
    // `isPro` (below) is kept as a derived getter for backward compat
    // with every existing call site — `userTier != .free` is the new
    // truth, but old callers still read the cached boolean. The legacy
    // licence-key format check ALSO flips `isPro` true on its own so
    // existing Paddle-key installs don't lose Pro entitlements at
    // upgrade time; explicit `userTier` overrides only matter when the
    // user has been promoted to Max (or demoted to Free) manually.
    private static let kUserTier = "Corder.set.userTier"
    static var userTier: UserTier {
        UserTier(rawValue: UserDefaults.standard.string(forKey: kUserTier) ?? "") ?? .free
    }
    static func setUserTier(_ v: UserTier) {
        UserDefaults.standard.set(v.rawValue, forKey: kUserTier)
    }

    // Admin role, mirrored from the signed-in Supabase user's
    // `app_metadata.role == "admin"` by `SupabaseTierSync`. Drives the
    // blue profile avatar so the operator can confirm at a glance that
    // the server-side admin grant landed in their session. Purely a
    // visual cue on the client — every privileged action is still
    // re-checked against the admin JWT by corder-api.
    private static let kIsAdmin = "Corder.set.isAdmin"
    static var isAdmin: Bool {
        UserDefaults.standard.bool(forKey: kIsAdmin)
    }
    static func setIsAdmin(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: kIsAdmin)
    }

    static var isPro: Bool {
        if userTier == .pro || userTier == .max { return true }
        guard let k = licenceKey else { return false }
        return isValidLicenceFormat(k)
    }

    // Display name harvested from the OAuth provider (Google `name`
    // claim, Apple full-name on first sign-in). Used in the profile
    // popover header. Optional — email-only sign-ups leave it nil.
    private static let kUserName = "Corder.set.userName"
    static var userName: String? {
        let raw = (UserDefaults.standard.string(forKey: kUserName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
    static func setUserName(_ name: String?) {
        let cleaned = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            UserDefaults.standard.removeObject(forKey: kUserName)
        } else {
            UserDefaults.standard.set(cleaned, forKey: kUserName)
        }
    }

    // Email used to sign in (Google OAuth `email` claim or the
    // email field on email/password sign-in). Surfaced in the
    // profile popover header under the display name. Optional —
    // we never auto-derive it, the sign-in flow has to set it.
    private static let kUserEmail = "Corder.set.userEmail"
    static var userEmail: String? {
        let raw = (UserDefaults.standard.string(forKey: kUserEmail) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
    static func setUserEmail(_ email: String?) {
        let cleaned = (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            UserDefaults.standard.removeObject(forKey: kUserEmail)
        } else {
            UserDefaults.standard.set(cleaned, forKey: kUserEmail)
        }
    }

    /// Sticky "has this install seen at least one successful sign-in?"
    /// flag. Stays true across Sign Out cycles so the post-OAuth
    /// toast can say "Welcome back" on the second-and-later sign-ins
    /// (only the very first time gets the bare "Welcome"). Cleared
    /// only by a full UserDefaults wipe.
    private static let kHasSignedInBefore = "Corder.user.hasSignedInBefore"
    static var hasSignedInBefore: Bool { UserDefaults.standard.bool(forKey: kHasSignedInBefore) }
    static func setHasSignedInBefore(_ v: Bool) { UserDefaults.standard.set(v, forKey: kHasSignedInBefore) }

    /// One-time flag: have we pushed the pre-Supabase local meetings
    /// to the cloud yet? Set true after the first successful backfill
    /// pass; checked on every launch so re-runs of the backfill are
    /// cheap no-ops. Cleared only by a full UserDefaults wipe (which
    /// also wipes the local DB, so backfill would have nothing to do).
    private static let kCloudBackfillDone = "Corder.user.cloudBackfillDone"
    static var cloudBackfillDone: Bool { UserDefaults.standard.bool(forKey: kCloudBackfillDone) }
    static func setCloudBackfillDone(_ v: Bool) { UserDefaults.standard.set(v, forKey: kCloudBackfillDone) }

    /// Explicit opt-in for the one-time legacy-meetings backfill. On
    /// a dev box where several Google accounts share one local
    /// SQLite, the first sign-in shouldn't silently claim every
    /// pre-Supabase recording as that account's — the user has to
    /// say "yes, attach all my local recordings to THIS account".
    /// Toggle from CLI: `defaults write com.3mpq.Corder Corder.user.cloudBackfillOptIn -bool true`.
    /// Single-user-on-one-Mac case = set once and forget; UI surface
    /// for it lives in Settings next session.
    private static let kCloudBackfillOptIn = "Corder.user.cloudBackfillOptIn"
    static var cloudBackfillOptedIn: Bool { UserDefaults.standard.bool(forKey: kCloudBackfillOptIn) }
    static func setCloudBackfillOptedIn(_ v: Bool) { UserDefaults.standard.set(v, forKey: kCloudBackfillOptIn) }

    /// Last Supabase user UUID we synced the local cache against.
    /// When a different user signs in on the same Mac we wipe the
    /// local meetings cache (otherwise account A would see account
    /// B's recordings — the local SQLite is per-machine, not per-
    /// user). Empty / nil means "fresh install, never synced".
    private static let kLastSyncedUserId = "Corder.user.lastSyncedUserId"
    static var lastSyncedUserId: String? {
        let raw = (UserDefaults.standard.string(forKey: kLastSyncedUserId) ?? "")
        return raw.isEmpty ? nil : raw
    }
    static func setLastSyncedUserId(_ id: String?) {
        if let id, !id.isEmpty {
            UserDefaults.standard.set(id, forKey: kLastSyncedUserId)
        } else {
            UserDefaults.standard.removeObject(forKey: kLastSyncedUserId)
        }
    }

    // First-run onboarding flag. Unlike every other Bool here, this
    // one defaults to **false** (the Welcome wizard should open the
    // FIRST time, not silently skip). Flipped to true only when the
    // user clicks "Done" on the final wizard step.
    private static let kOnboardingDone = "Corder.set.onboardingCompleted"
    static var onboardingCompleted: Bool {
        UserDefaults.standard.bool(forKey: kOnboardingDone)
    }
    static func setOnboardingCompleted(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: kOnboardingDone)
    }

    // Resume slot for the Welcome wizard. macOS permission grants
    // (Microphone, Screen Recording) sometimes require a relaunch
    // to take effect — without persisting "which step the user was
    // on", the wizard would always reopen on step 1 and lose the
    // user's progress through the funnel. Stored as a raw `Int`
    // matching `WizardStep.rawValue`. 0 = welcome (default).
    private static let kOnboardingStep = "Corder.set.onboardingStep"
    static var onboardingStep: Int {
        UserDefaults.standard.integer(forKey: kOnboardingStep)
    }
    static func setOnboardingStep(_ step: Int) {
        UserDefaults.standard.set(step, forKey: kOnboardingStep)
    }

    // Demo-data seed flag. `DemoSeeder` flips this true after its
    // one-shot pass on first launch. Re-seeding still happens when
    // the SEED VERSION bumps (see `demoDataSeedVersion`), which lets
    // us ship new sample content to existing installs by dropping the
    // previously seeded rows and re-inserting the current templates.
    private static let kDemoDataSeeded = "Corder.set.demoDataSeeded"
    static var demoDataSeeded: Bool {
        UserDefaults.standard.bool(forKey: kDemoDataSeeded)
    }
    static func setDemoDataSeeded(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: kDemoDataSeeded)
    }

    /// Stored seed-content version. Compared against
    /// `DemoSeeder.currentSeedVersion` on launch — mismatch triggers
    /// a re-seed (old rows are removed by id, fresh ones inserted).
    /// Defaults to 0 so any non-zero current version on a brand-new
    /// install or an install that pre-dated the version field will
    /// re-seed once.
    private static let kDemoDataSeedVersion = "Corder.set.demoDataSeedVersion"
    static var demoDataSeedVersion: Int {
        UserDefaults.standard.integer(forKey: kDemoDataSeedVersion)
    }
    static func setDemoDataSeedVersion(_ v: Int) {
        UserDefaults.standard.set(v, forKey: kDemoDataSeedVersion)
    }

    /// IDs of the meetings DemoSeeder inserted. We keep them so the
    /// re-seed path can delete the exact rows it owns without touching
    /// any meeting the user recorded themselves.
    private static let kDemoSeededIDs = "Corder.set.demoSeededIDs"
    static var demoSeededIDs: [String] {
        UserDefaults.standard.stringArray(forKey: kDemoSeededIDs) ?? []
    }
    static func setDemoSeededIDs(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: kDemoSeededIDs)
    }
}

enum SourceMode: String {
    case full   // full screen
    case window // pick a window each time
}

/// Paid-tier ladder. Free = baseline; Pro = paying customer; Max =
/// top-tier ($everything-unlimited bundle). Stored in UserDefaults
/// under `Corder.set.userTier`; default = `.free` when the key is
/// absent. `AppSettings.isPro` is `true` for both `.pro` and `.max`.
enum UserTier: String { case free, pro, max }

extension UserTier {
    /// Per-tier monthly cap on "advanced" transcription seconds —
    /// the cloud models (Gemini, Whisper-cloud) that cost real
    /// compute. Returning `nil` means unlimited (the Max tier; the
    /// Usage bar pins to "unlimited"). On-device `whisperLocal` is
    /// unmetered for every tier.
    var advancedMonthlyLimitSeconds: Int? {
        switch self {
        case .free: return 60 * 60        // 1 hour / month
        case .pro:  return 1500 * 60      // 25 hours / month
        case .max:  return nil            // unlimited
        }
    }
}

extension TranscriptionProvider {
    /// Two-tier classification used by `/api/usage` and the Dashboard
    /// Usage bars. Cloud models map to "advanced" (billed per minute);
    /// on-device WhisperKit maps to "local" (free for all tiers).
    var usageClass: String {
        switch self {
        case .gemini, .whisper, .groq: return "advanced"
        case .whisperLocal:            return "local"
        }
    }
}

/// ASR provider selector. Three providers in the wild now:
///   • `.gemini`         — Gemini 2.5 Flash (cloud, default). $0.30/h-ish.
///   • `.whisper`        — OpenAI whisper-1 + gpt-4o-mini polish (cloud).
///                         ~$0.36/h before the LLM polish stage.
///   • `.whisperLocal`   — WhisperKit (Core ML, on-device). Apple Silicon
///                         only; falls back to `.gemini` at the pipeline
///                         level when run on Intel. $0/h after the
///                         one-time ~1.5 GB multilingual model download.
enum TranscriptionProvider: String {
    case gemini         // gemini-2.5-flash (default)
    case whisper        // OpenAI whisper-1 + gpt-4o-mini polish
    case groq           // Groq Whisper-large-v3-turbo (no polish; ~10× cheaper than whisper-1)
    case whisperLocal   // WhisperKit on-device (Apple Silicon)
}

enum RecordingState: Equatable {
    case idle
    case recording(meetingId: String, startedAt: Date)
    case stopping
    /// Silent pre-roll: capture is alive (the meeting is being recorded
    /// from the moment a call was detected) but nothing is shown — no HUD,
    /// no menu-bar change, the row is hidden. If the user accepts the
    /// "record this call?" offer it's promoted to `.recording` keeping the
    /// captured-from-the-start audio/video; if they decline (or the call
    /// ends first) it's discarded as if it never happened. Opt-in, gated by
    /// `AppSettings.prerollEnabled` (default OFF).
    case preroll(meetingId: String, startedAt: Date)
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
