import Foundation

enum DTO {
    struct MeetingSummary: Codable {
        let id: String
        let started_at: Int64
        let ended_at: Int64?
        let duration_ms: Int64?
        let status: String
        let title: String?
        let preview: String?
        let speaker_count: Int
        /// Speaker labels + custom names, joined by " · ". Used by the
        /// sidebar's text filter so the user can find a meeting by who
        /// was on the call ("Vadim", "Влад", etc.) without opening it.
        let speaker_names: String?
        let pinned: Bool
        /// `false` = the user hasn't opened this meeting yet. Drives the
        /// "unseen" accent on the title in the sidebar + Recent.
        let viewed: Bool
    }

    struct MeetingDetail: Codable {
        let id: String
        let started_at: Int64
        let duration_ms: Int64?
        let status: String
        let title: String?
        let summary: String?
        let speakers: [SpeakerDTO]
        let segments: [SegmentDTO]
        let expected_other_speakers: Int?
        /// True if the meeting has a playable video.mov — either on
        /// disk in recordingDir or archived to Dropbox. The frontend
        /// uses this to decide whether to render the `<video>` block
        /// above the audio player.
        let has_video: Bool
        /// True when a PLAYABLE audio file exists (the audio.wav mix, or the
        /// raw mic.wav, or a Dropbox-archived copy). The player gates its Play
        /// button on this instead of `duration_ms > 0`: an orphaned/rescued row
        /// can carry a 0/nil duration yet still have real audio on disk, and the
        /// old gate greyed the control out on a perfectly playable recording.
        let has_audio: Bool
        /// JSON string with `[{start_ms, title}]` for the Chapters tab.
        /// Returned as-is from the DB column; frontend parses it.
        let chapters: String?
        /// Unix-ms timestamp the pipeline first flipped this meeting
        /// into `.transcribing`. The Transcribing banner uses it for
        /// the inline elapsed counter so the timer reflects the
        /// backend's real start, not a fresh "00:00" on every
        /// MeetingView mount. `nil` for legacy rows (banner falls
        /// back to "now").
        let transcribing_started_at: Int64?
        /// REAL transcription progress 0…1 while `status == "transcribing"`,
        /// fed by the local ASR window-by-window. `nil` when not in flight.
        let transcribe_progress: Double?
        /// On-device model download progress 0…1 while `status ==
        /// "transcribing"` BUT the local Whisper model is still fetching
        /// (~1.5 GB, first run on a new free-tier Mac). `nil` when the model
        /// is ready or not the local provider. The banner shows a
        /// "Downloading model" state with this fill, then switches to
        /// `transcribe_progress` once the model lands. Without it a new user
        /// just sees a frozen spinner for minutes.
        let model_download_progress: Double?
        /// True while the model bytes are fully down but we're in the SILENT
        /// post-download phase — staging the tokenizer + the one-time ANE
        /// Core ML compile (minutes on a slow Mac, no progress callbacks).
        /// Progress is pinned at 0.99 here, so the frontend uses this to show
        /// a "Preparing model…" / indeterminate state instead of a frozen
        /// "Downloading model · 99%" that reads as a stuck download.
        let model_preparing: Bool?
    }

    struct ExpectedSpeakersRequest: Codable {
        let count: Int?
    }

    /// `GET /api/usage` — drives the Dashboard Usage bars. The
    /// frontend renders a real fill when `limit_seconds` is non-null
    /// and a shimmer when it's null (unlimited). `resets_at` is the
    /// first instant of next calendar month in Unix-ms — same for
    /// both classes (single billing window).
    struct Usage: Codable {
        let plan: String                       // "free" | "pro" | "max"
        let advanced: Bucket
        let local: Bucket
        let resets_at_ms: Int64

        struct Bucket: Codable {
            let used_seconds: Int64
            /// `nil` = unlimited.
            let limit_seconds: Int?
        }
    }

    struct Settings: Codable {
        let language: String?
        /// Domain terms (names / jargon / acronyms) fed into the
        /// transcription prompt to improve accuracy. Free-form text.
        let vocabulary: String?
        /// Write-only: POST a new Gemini API key here. Never echoed back
        /// by GET (so the key isn't exposed to the page after it's set).
        let gemini_key: String?
        /// Read-only: GET reports whether a key is on disk, not the key.
        let gemini_key_set: Bool?
        /// Functional toggles. All optional so an older client that
        /// omits a field never flips it — `settingsSet` treats absent
        /// as "leave unchanged" (migration/compat guarantee). Defaults
        /// live in `AppSettings` (every Bool → true).
        let notifications: Bool?
        /// Floating recording HUD (the live equalizer pill). Default ON;
        /// toggling off suppresses the pill for the whole session.
        let hud_enabled: Bool?
        let capture_video: Bool?
        /// Record screen video at native resolution (up to 4K) instead of the
        /// small default. Opt-in + sign-in-gated (the UI only offers it to a
        /// signed-in user with screen video on; capture enforces sign-in).
        let capture_video_hires: Bool?
        /// Read-only: whether macOS Screen Recording is currently granted to
        /// Corder. Drives the "ghost video" CTA in the recording panel (video
        /// capture is unavailable until this is true).
        let screen_recording_granted: Bool?
        /// Mic + system are ONE switch on purpose: the dual-track
        /// pipeline assumes both WAVs exist; splitting them would drop
        /// into the legacy single-stream channel-gate path.
        let capture_audio: Bool?
        let auto_transcribe: Bool?
        let auto_title: Bool?
        /// Run `GeminiSummarizer` automatically once the transcript is
        /// ready, so the Summary tab is pre-populated on first open.
        let auto_summary: Bool?
        /// Run `GeminiChapters` automatically once the transcript is
        /// ready, so the Chapters tab is pre-populated on first open.
        let auto_chapters: Bool?
        /// Register Corder as a login item (launch on boot / login).
        /// Backed by `SMAppService.mainApp`.
        let launch_at_login: Bool?
        /// Opt-in diagnostic telemetry — default off. When on, the
        /// app ships diagnostic counts (no PII / no transcript) to
        /// the maintainer's Worker once per 24h.
        let telemetry: Bool?
        /// Dashboard statistics block visibility. Default off; the toggle
        /// is paid-only (gated in the web SettingsPane).
        let stats_enabled: Bool?
        /// Silent pre-roll: start capturing when a call is detected so
        /// accepting the offer keeps audio/video from the start. Opt-in,
        /// default OFF (records before consent, then discards on decline).
        let preroll: Bool?
        /// User-managed bundle ids: always offer to record for these /
        /// never offer for these. Consumed by `MeetingDetector`.
        let meeting_whitelist: [String]?
        let meeting_blacklist: [String]?
        /// Read-only: bundle ids recently seen owning the mic, so the
        /// UI can offer a tap-to-add picker (no bundle-id typing).
        let detected_mic_apps: [String]?
        /// Preferred microphone input device. Stored as the stable
        /// Core Audio UID (not the numeric AudioDeviceID, which the
        /// OS re-issues on reboot/replug). `nil` / empty string =
        /// "use system default" — the pre-feature behaviour.
        let mic_device_uid: String?
        /// Read-only: discovered input devices for the picker. Sorted
        /// with the current system default first.
        let audio_input_devices: [AudioInputDeviceDTO]?
        /// Paddle-issued licence key (raw string the user pasted into
        /// the Welcome wizard). Empty / nil = Free tier. The frontend
        /// also reads `is_pro` for the derived state — keeping both
        /// avoids re-implementing the format rule in TypeScript.
        let licence_key: String?
        /// Display name harvested from the sign-in provider (Google
        /// `name` claim / Apple full name / user-entered). Drives the
        /// profile popover header; nil when no name was provided.
        let user_name: String?
        /// Email used to sign in. Drives the line under the name in
        /// the profile popover. nil when the user signed in without
        /// an email (e.g. trial path, if we add one).
        let user_email: String?
        /// Read-only: server-derived "this licence currently looks Pro"
        /// flag. MVP rule lives in `AppSettings.isValidLicenceFormat`
        /// (≥ 20 alphanumeric/dash/underscore).
        let is_pro: Bool?
        /// Read-only: `true` when the signed-in account has the admin
        /// role (`app_metadata.role == "admin"`), mirrored from the
        /// Supabase session by `SupabaseTierSync`. Drives the blue
        /// profile avatar. Display-only — never a privilege grant.
        let is_admin: Bool?
        /// Read-only: current paid-tier ladder rung — `free` / `pro` /
        /// `max`. Source of truth on the server, mirrors
        /// `AppSettings.userTier`. The frontend reads this directly to
        /// drive the tier badge + the Sidebar Upgrade card visibility;
        /// `is_pro` is kept as the older boolean for backward-compat.
        let tier: String?
        /// Read-only: has the user finished the Welcome wizard at least
        /// once? AppDelegate uses this to decide whether to auto-open
        /// the wizard on launch. The wizard's final step flips it.
        let onboarding_completed: Bool?
        /// ASR provider override. `"auto"` means "no override stored —
        /// let `AppSettings.transcriptionProvider` pick by tier" (Free
        /// → whisperLocal, Pro/Max → whisper). The three concrete
        /// values map 1:1 to `TranscriptionProvider.rawValue`:
        /// `"gemini"` / `"whisper"` / `"whisperLocal"`. POST `"auto"`
        /// to clear the override; POST a concrete value to pin.
        let transcription_provider: String?
        /// Forced transcription language (ISO-639-1, e.g. `"ru"`). Empty
        /// string = auto-detect. Feeds Whisper (cloud + local); Gemini
        /// already preserves the spoken language verbatim.
        let transcription_language: String?
        /// Read-only: is the currently-active WhisperKit variant fully
        /// downloaded (AudioEncoder.mlmodelc + TextDecoder.mlmodelc
        /// both present)? Convenience flag retained for the
        /// transcription-pipeline UI; per-variant state lives in
        /// `whisper_local_models`.
        let whisper_local_model_ready: Bool?
        /// Picked Whisper Local variant id — only `openai_whisper-large-v3_turbo`
        /// now (Whisper Small + base/tiny were dropped). Echoed back unchanged;
        /// absent means the server hasn't seen one yet and is using the
        /// default (turbo).
        let whisper_local_variant: String?
        /// JSON-encoded `{speed: ts, best: ts, unlimited: ts}` map —
        /// timestamps the user dismissed the matching upsell strip at.
        /// Lives in UserDefaults on the native side because the
        /// WKWebView's localStorage gets wiped if Swifter binds a
        /// different port at next launch.
        let upsell_snooze: String?
        /// Per-variant catalogue with ready/downloading/progress state.
        /// Frontend renders this directly as the SettingsSelect option
        /// list AND the DownloadButton state under the picker.
        let whisper_local_models: [WhisperLocalModelDTO]?
        /// Read-only: is the current Mac an Apple Silicon device?
        /// WhisperKit's Core ML kernels are arm64-only; on Intel the
        /// picker still surfaces the option but warns the user it will
        /// silently fall back to cloud.
        let apple_silicon: Bool?
    }

    /// One installable WhisperKit variant. The frontend renders these
    /// as the four options inside the Transcription model SettingsSelect
    /// (label + size meta) AND as the source of truth for the
    /// DownloadButton state under the picker. `progress` is `nil`
    /// when the model isn't currently downloading.
    struct WhisperLocalModelDTO: Codable {
        /// Raw variant id (`openai_whisper-large-v3_turbo` etc.) — used
        /// as the value in the SettingsSelect and the body of POST
        /// `/api/whisper-local/download`.
        let id: String
        /// Display label shown in the picker ("Whisper Turbo").
        let label: String
        /// Human-readable size shown as the meta after the label
        /// ("1.5 GB" / "480 MB").
        let size_label: String
        /// Integer MB — lets the frontend sort or render an exact byte
        /// count if it wants to.
        let size_mb: Int
        /// True when the model's Core ML packages are fully on disk.
        let ready: Bool
        /// `0.0…1.0` while WhisperKit is fetching this variant. `nil`
        /// when no download is in flight.
        let progress: Double?
    }

    /// One discoverable microphone-class device. Mirrors
    /// `AudioInputDevices.Info` so the frontend doesn't have to know
    /// about Core Audio constants.
    struct AudioInputDeviceDTO: Codable {
        let uid: String
        let name: String
        let manufacturer: String?
        /// "BuiltIn" / "USB" / "Bluetooth" / "Virtual" / "Aggregate" /
        /// "Continuity" / etc. — used for an icon hint in the picker.
        let transport: String?
        let is_system_default: Bool
    }

    /// One installed application, for the Settings app-picker (so the
    /// user adds Zoom/Discord/their browser by tapping, not by typing a
    /// bundle id). `recent` = Corder has seen it own the mic lately.
    struct InstalledApp: Codable {
        let bundle: String
        let name: String
        let recent: Bool
    }

    struct SpeakerDTO: Codable {
        let id: String
        let label: String
        let custom_name: String?
        let color_hex: String
    }

    struct SegmentDTO: Codable {
        let id: Int64
        let speaker_id: String
        let start_ms: Int64
        let end_ms: Int64
        let text: String
        let text_boost: String?
    }

    struct RenameRequest: Codable {
        let name: String?
    }

    /// Meeting title override from the sidebar context-menu "Rename".
    /// `nil`/empty clears it back to the auto/date label.
    struct MeetingTitleRequest: Codable {
        let title: String?
    }

    /// Dashboard "Upcoming" tab feed. `connected` is false until the
    /// user grants calendar access; the frontend keys its Connect vs
    /// empty state off it.
    struct UpcomingResponse: Codable {
        let connected: Bool
        let events: [UpcomingEvent]
    }
    struct UpcomingEvent: Codable {
        let id: String
        let title: String
        let start_ms: Int64
        let end_ms: Int64?
        let attendees: Int?
        let platform: String?
        let join_url: String?
    }

    /// Right-click → "Edit" on a transcript segment.
    struct SegmentTextRequest: Codable {
        let text: String
    }

    /// Right-click → "Assign to" — move a segment to another speaker.
    struct SegmentSpeakerRequest: Codable {
        let speaker_id: String
    }

    /// Right-click speaker → "Merge into" — fold this speaker's segments
    /// into another and drop the source row.
    struct MergeSpeakerRequest: Codable {
        let into: String
    }

    struct SearchHit: Codable {
        let meeting_id: String
        let segment_id: Int64
        let start_ms: Int64
        let text: String
    }
}
