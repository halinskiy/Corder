import Foundation
import GRDB

struct MeetingRepository {
    let dbq: DatabaseQueue

    func insertMeeting(_ m: Meeting) throws {
        try dbq.write { try m.insert($0) }
    }

    func updateMeeting(_ m: Meeting) throws {
        try dbq.write { try m.update($0) }
    }

    func deleteMeeting(id: String) throws {
        try dbq.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
        }
    }

    func meeting(id: String) throws -> Meeting? {
        try dbq.read { try Meeting.fetchOne($0, key: id) }
    }

    func listMeetings() throws -> [Meeting] {
        try dbq.read { db in
            try Meeting.order(Column("started_at").desc).fetchAll(db)
        }
    }

    func insertSpeaker(_ s: Speaker) throws {
        try dbq.write { try s.insert($0) }
    }

    func renameSpeaker(speakerId: String, customName: String?) throws {
        try dbq.write { db in
            try db.execute(sql: "UPDATE speakers SET custom_name = ? WHERE id = ?",
                           arguments: [customName, speakerId])
        }
    }

    func speakers(forMeeting id: String) throws -> [Speaker] {
        try dbq.read { db in
            try Speaker
                .filter(Column("meeting_id") == id)
                .order(Column("label"))
                .fetchAll(db)
        }
    }

    func insertSegment(_ s: Segment) throws {
        try dbq.write { try s.insert($0) }
    }

    func segments(forMeeting id: String) throws -> [Segment] {
        try dbq.read { db in
            try Segment
                .filter(Column("meeting_id") == id)
                .order(Column("start_ms"))
                .fetchAll(db)
        }
    }

    func searchSegments(query: String) throws -> [Segment] {
        try dbq.read { db in
            try Segment.fetchAll(db, sql: """
                SELECT s.* FROM segments s
                JOIN segments_fts f ON f.rowid = s.id
                WHERE segments_fts MATCH ?
                ORDER BY rank
            """, arguments: [query])
        }
    }
}
