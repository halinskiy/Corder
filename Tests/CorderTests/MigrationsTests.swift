import XCTest
import GRDB
@testable import Corder

final class MigrationsTests: XCTestCase {
    func test_v1_creates_all_tables() throws {
        let dbq = try DatabaseQueue()
        try Migrations.register().migrate(dbq)

        try dbq.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type IN ('table','virtual table')
                ORDER BY name
            """)
            XCTAssertTrue(tables.contains("meetings"))
            XCTAssertTrue(tables.contains("speakers"))
            XCTAssertTrue(tables.contains("segments"))
            XCTAssertTrue(tables.contains("segments_fts"))
        }
    }

    func test_fts5_round_trips_text() throws {
        let dbq = try DatabaseQueue()
        try Migrations.register().migrate(dbq)

        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO meetings(id, started_at, video_path, audio_path, status)
                VALUES ('m1', 1000, 'v', 'a', 'ready')
            """)
            try db.execute(sql: """
                INSERT INTO speakers(id, meeting_id, label, color_hex)
                VALUES ('s1', 'm1', 'Speaker 1', '#000')
            """)
            try db.execute(sql: """
                INSERT INTO segments(meeting_id, speaker_id, start_ms, end_ms, text)
                VALUES ('m1', 's1', 0, 1000, 'hello world')
            """)
        }

        let hits = try dbq.read { db in
            try Int.fetchAll(db, sql: "SELECT rowid FROM segments_fts WHERE segments_fts MATCH 'hello'")
        }
        XCTAssertEqual(hits.count, 1)
    }
}
