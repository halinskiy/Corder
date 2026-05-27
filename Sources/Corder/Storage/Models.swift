import Foundation
import GRDB

enum MeetingStatus: String, Codable, DatabaseValueConvertible {
    case recording, transcribing, ready, failed
}

struct Meeting: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetings"
    // Optional fields default to nil so the synthesised memberwise init can
    // be called with only the required arguments (id / startedAt / paths /
    // status) — keeps callers from having to pass `nil` for every metadata
    // field they don't care about, and adding new optional columns won't
    // break the call sites.
    var id: String
    var startedAt: Int64
    var endedAt: Int64? = nil
    var durationMs: Int64? = nil
    var videoPath: String
    var audioPath: String
    var transcribedAt: Int64? = nil
    var status: MeetingStatus
    var dropboxVideoPath: String? = nil
    var dropboxAudioPath: String? = nil
    var dropboxUploadedAt: Int64? = nil
    var expectedOtherSpeakers: Int? = nil
    var geminiRawTurns: String? = nil
    var audioHash: String? = nil
    var archivedAt: Int64? = nil
    /// Auto-generated short headline (3-6 words, transcript language).
    /// nil until the post-transcription title pass fills it.
    var title: String? = nil
    /// Generated meeting summary (Markdown, transcript language). nil
    /// until the user opens the Summary tab (generated on demand).
    var summary: String? = nil
    /// Non-nil = pinned; value is when it was pinned (stable order
    /// within the pinned group).
    var pinnedAt: Int64? = nil
    /// Whether the default OUTPUT route was Bluetooth when recording
    /// started. Persisted (not read live) because the capture engine is
    /// a singleton — a deferred / re-transcribe run would otherwise see
    /// the *current* route. Drives the system-track chooser: on BT the
    /// Core-Audio tap is faint, so the SCStream backup is authoritative.
    var outputBluetoothAtStart: Bool? = nil
    /// Timestamp the user first opened this meeting in the Library
    /// window. Null = unseen → the sidebar / Recent renders the
    /// title in the unseen accent. Stamped on the first GET
    /// `/api/meetings/:id` after the row finishes transcribing.
    var viewedAt: Int64? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMs = "duration_ms"
        case videoPath = "video_path"
        case audioPath = "audio_path"
        case transcribedAt = "transcribed_at"
        case status
        case dropboxVideoPath = "dropbox_video_path"
        case dropboxAudioPath = "dropbox_audio_path"
        case dropboxUploadedAt = "dropbox_uploaded_at"
        case expectedOtherSpeakers = "expected_other_speakers"
        case geminiRawTurns = "gemini_raw_turns"
        case audioHash = "audio_hash"
        case archivedAt = "archived_at"
        case title
        case summary
        case pinnedAt = "pinned_at"
        case outputBluetoothAtStart = "output_bluetooth_at_start"
        case viewedAt = "viewed_at"
    }
}

struct Speaker: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "speakers"
    var id: String
    var meetingId: String
    var label: String
    var customName: String? = nil
    var colorHex: String

    enum CodingKeys: String, CodingKey {
        case id
        case meetingId = "meeting_id"
        case label
        case customName = "custom_name"
        case colorHex = "color_hex"
    }
}

struct Segment: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "segments"
    var id: Int64? = nil
    var meetingId: String
    var speakerId: String
    var startMs: Int64
    var endMs: Int64
    var text: String
    var wordsJson: String? = nil
    var textBoost: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case meetingId = "meeting_id"
        case speakerId = "speaker_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case text
        case wordsJson = "words_json"
        case textBoost = "text_boost"
    }
}
