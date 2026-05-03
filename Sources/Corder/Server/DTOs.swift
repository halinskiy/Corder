import Foundation

enum DTO {
    struct MeetingSummary: Codable {
        let id: String
        let started_at: Int64
        let ended_at: Int64?
        let duration_ms: Int64?
        let status: String
        let preview: String?
        let speaker_count: Int
    }

    struct MeetingDetail: Codable {
        let id: String
        let started_at: Int64
        let duration_ms: Int64?
        let status: String
        let speakers: [SpeakerDTO]
        let segments: [SegmentDTO]
        let boosted_text: String?
        let boosted_at: Int64?
    }

    struct BoostResponse: Codable {
        let ok: Bool
        let error: String?
    }

    struct Settings: Codable {
        let boost_mode: Bool
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

    struct SearchHit: Codable {
        let meeting_id: String
        let segment_id: Int64
        let start_ms: Int64
        let text: String
    }
}
