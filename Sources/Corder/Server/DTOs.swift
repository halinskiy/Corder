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
    }

    struct ExpectedSpeakersRequest: Codable {
        let count: Int?
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
