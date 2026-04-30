import Foundation
import GRDB

enum MeetingStatus: String, Codable, DatabaseValueConvertible {
    case recording, transcribing, ready, failed
}

struct Meeting: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetings"
    var id: String
    var startedAt: Int64
    var endedAt: Int64?
    var durationMs: Int64?
    var videoPath: String
    var audioPath: String
    var transcribedAt: Int64?
    var status: MeetingStatus

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMs = "duration_ms"
        case videoPath = "video_path"
        case audioPath = "audio_path"
        case transcribedAt = "transcribed_at"
        case status
    }
}

struct Speaker: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "speakers"
    var id: String
    var meetingId: String
    var label: String
    var customName: String?
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
    var id: Int64?
    var meetingId: String
    var speakerId: String
    var startMs: Int64
    var endMs: Int64
    var text: String
    var wordsJson: String?

    enum CodingKeys: String, CodingKey {
        case id
        case meetingId = "meeting_id"
        case speakerId = "speaker_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case text
        case wordsJson = "words_json"
    }
}
