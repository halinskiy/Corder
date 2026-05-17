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
