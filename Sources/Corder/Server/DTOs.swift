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
        let capture_video: Bool?
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
        /// User-managed bundle ids: always offer to record for these /
        /// never offer for these. Consumed by `MeetingDetector`.
        let meeting_whitelist: [String]?
        let meeting_blacklist: [String]?
        /// Read-only: bundle ids recently seen owning the mic, so the
        /// UI can offer a tap-to-add picker (no bundle-id typing).
        let detected_mic_apps: [String]?
        /// Global record hotkey. Write: Carbon virtual key code + Carbon
        /// modifier mask (cmd 256 | shift 512 | option 2048 | ctrl 4096).
        let record_hotkey_code: Int?
        let record_hotkey_mods: Int?
        /// Read-only: human label (e.g. "⌘⇧F"), the name of a clashing
        /// macOS *system* shortcut if any (nil = none known; third-party
        /// app clashes are undetectable), and whether the OS actually
        /// bound it.
        let record_hotkey_label: String?
        let record_hotkey_conflict: String?
        let record_hotkey_ok: Bool?
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
        /// Read-only: is the currently-active WhisperKit variant fully
        /// downloaded (AudioEncoder.mlmodelc + TextDecoder.mlmodelc
        /// both present)? Convenience flag retained for the
        /// transcription-pipeline UI; per-variant state lives in
        /// `whisper_local_models`.
        let whisper_local_model_ready: Bool?
        /// Picked Whisper Local variant id (`openai_whisper-large-v3_turbo` /
        /// `openai_whisper-small` / `openai_whisper-base` /
        /// `openai_whisper-tiny`). Echoed back unchanged; absent means
        /// the server hasn't seen one yet and is using the default
        /// (turbo).
        let whisper_local_variant: String?
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

    struct SearchHit: Codable {
        let meeting_id: String
        let segment_id: Int64
        let start_ms: Int64
        let text: String
    }
}
