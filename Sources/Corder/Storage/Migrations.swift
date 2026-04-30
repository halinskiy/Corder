import GRDB

enum Migrations {
    static func register() -> DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE meetings (
                  id              TEXT PRIMARY KEY,
                  started_at      INTEGER NOT NULL,
                  ended_at        INTEGER,
                  duration_ms     INTEGER,
                  video_path      TEXT NOT NULL,
                  audio_path      TEXT NOT NULL,
                  transcribed_at  INTEGER,
                  status          TEXT NOT NULL
                );
            """)
            try db.execute(sql: """
                CREATE TABLE speakers (
                  id           TEXT PRIMARY KEY,
                  meeting_id   TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  label        TEXT NOT NULL,
                  custom_name  TEXT,
                  color_hex    TEXT NOT NULL
                );
            """)
            try db.execute(sql: """
                CREATE TABLE segments (
                  id          INTEGER PRIMARY KEY,
                  meeting_id  TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  speaker_id  TEXT NOT NULL REFERENCES speakers(id) ON DELETE CASCADE,
                  start_ms    INTEGER NOT NULL,
                  end_ms      INTEGER NOT NULL,
                  text        TEXT NOT NULL,
                  words_json  TEXT
                );
            """)
            try db.execute(sql: """
                CREATE INDEX idx_segments_meeting_start
                ON segments(meeting_id, start_ms);
            """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE segments_fts USING fts5(
                  text,
                  content='segments',
                  content_rowid='id'
                );
            """)
            try db.execute(sql: """
                CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
                  INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN
                  INSERT INTO segments_fts(segments_fts, rowid, text) VALUES('delete', old.id, old.text);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER segments_au AFTER UPDATE ON segments BEGIN
                  INSERT INTO segments_fts(segments_fts, rowid, text) VALUES('delete', old.id, old.text);
                  INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
                END;
            """)
        }
        return m
    }
}
