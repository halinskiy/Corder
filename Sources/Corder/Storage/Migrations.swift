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

        m.registerMigration("v2_boost") { db in
            try db.execute(sql: """
                ALTER TABLE meetings ADD COLUMN boosted_text TEXT;
            """)
            try db.execute(sql: """
                ALTER TABLE meetings ADD COLUMN boosted_at INTEGER;
            """)
        }

        // Per-segment Boost: replaces the meeting-level "boosted_text" approach
        // with one cleaned-up string per Whisper segment. This way the structure
        // (timestamps, speaker grouping) stays the same and we can flip
        // raw↔boosted in the existing TranscriptPane without a separate view.
        m.registerMigration("v3_segment_boost") { db in
            try db.execute(sql: """
                ALTER TABLE segments ADD COLUMN text_boost TEXT;
            """)
        }

        // Dropbox archival: when a meeting's video has been uploaded to
        // Dropbox we store its remote path (e.g. /Corder/<id>/video.mov) and
        // an upload timestamp. Local files are deleted right after, so the
        // server falls back to a short-lived Dropbox temporary link when
        // the user opens an archived meeting.
        m.registerMigration("v4_dropbox") { db in
            try db.execute(sql: """
                ALTER TABLE meetings ADD COLUMN dropbox_video_path TEXT;
            """)
            try db.execute(sql: """
                ALTER TABLE meetings ADD COLUMN dropbox_audio_path TEXT;
            """)
            try db.execute(sql: """
                ALTER TABLE meetings ADD COLUMN dropbox_uploaded_at INTEGER;
            """)
        }

        // User-provided hint for diarization: how many participants were on
        // the call besides the local user. Optional — when set we pin
        // FluidAudio to that exact cluster count, otherwise we let it
        // auto-detect (and clean up with mergeTinyClusters).
        m.registerMigration("v5_expected_speakers") { db in
            try db.execute(sql: """
                ALTER TABLE meetings ADD COLUMN expected_other_speakers INTEGER;
            """)
        }

        // Drop the legacy meeting-level boost columns. These were superseded
        // by per-segment `text_boost` (v3) ages ago and have been written-only
        // dead weight since. SQLite 3.35+ supports DROP COLUMN; macOS 14 ships
        // 3.39, so this migration is safe.
        m.registerMigration("v6_drop_legacy_boost_columns") { db in
            try db.execute(sql: "ALTER TABLE meetings DROP COLUMN boosted_text;")
            try db.execute(sql: "ALTER TABLE meetings DROP COLUMN boosted_at;")
        }

        // Cache the raw Gemini transcription output so subsequent
        // re-mappings (clarify "1 speaker" → "3 speakers", etc.) don't
        // need to re-upload the audio and re-bill another generateContent.
        // `gemini_raw_turns` stores the array of {speaker, start_ms, end_ms,
        // text} dictionaries as JSON. `audio_hash` is the MD5 of the file
        // we sent to Gemini — used to invalidate the cache if the audio
        // gets re-mixed (e.g. user re-runs after a fix to AudioMixer).
        m.registerMigration("v7_gemini_raw_cache") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN gemini_raw_turns TEXT;")
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN audio_hash TEXT;")
        }

        // Soft-archive: when set to a non-null timestamp the meeting is
        // hidden from the main library and shown in the archive panel
        // instead. Records that have been archived for more than 7 days
        // get hard-deleted (DB row + Dropbox files) on the next launch.
        m.registerMigration("v8_archive") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN archived_at INTEGER;")
        }

        m.registerMigration("v9_title") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN title TEXT;")
        }

        m.registerMigration("v10_summary") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN summary TEXT;")
        }

        // Summaries generated before the "plain prose only" rule used a
        // structured Markdown format. Clear them so they regenerate in
        // the new format the next time the user opens the Summary tab.
        m.registerMigration("v11_reset_summaries") { db in
            try db.execute(sql: "UPDATE meetings SET summary = NULL;")
        }

        // Early auto-titles were one-word junk ("Го", "Э") from a weak
        // prompt on thin transcripts. Clear them so the launch backfill
        // regenerates with the stricter prompt (and skips untitleable
        // ones, leaving the date label).
        m.registerMigration("v12_reset_titles") { db in
            try db.execute(sql: "UPDATE meetings SET title = NULL;")
        }

        // The strict-prompt titler (v12 era) over-corrected: it answered
        // NONE for nearly everything, leaving real conversations on the
        // date label, while a weaker intermediate prompt had stamped junk
        // one-word titles ("Го", "Э", "L"). Clear again so the loosened
        // prompt re-titles every transcript on the next launch.
        m.registerMigration("v13_reset_titles_again") { db in
            try db.execute(sql: "UPDATE meetings SET title = NULL;")
        }

        // Pinned sessions: a non-null timestamp = pinned (the value is
        // when it was pinned, so the pinned group keeps a stable
        // most-recently-pinned-first order).
        m.registerMigration("v14_pin") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN pinned_at INTEGER;")
        }
        m.registerMigration("v15_bt_route") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN output_bluetooth_at_start INTEGER;")
        }
        // Per-meeting "seen" marker. A non-null timestamp means the user
        // has opened the meeting at least once; null = unseen (the title
        // is rendered in the unseen accent in the sidebar + Recent).
        // Existing rows stay NULL — that's wrong for old meetings on
        // first launch after upgrade (they'd all show as unseen), so
        // the second SQL statement seeds them as seen by stamping
        // viewed_at = ended_at where ended_at is set.
        m.registerMigration("v16_viewed_at") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN viewed_at INTEGER;")
            try db.execute(sql: "UPDATE meetings SET viewed_at = ended_at WHERE ended_at IS NOT NULL;")
        }
        // Timestamp the meeting first entered the .transcribing state.
        // Drives the inline elapsed counter in the Transcribing banner
        // so it reflects the BACKEND start, not when the user happened
        // to open the meeting view. Legacy rows stay NULL; the banner
        // falls back to `ended_at` (close enough — that's seconds
        // before the pipeline kicks off) and finally to "now" if both
        // are absent.
        m.registerMigration("v17_transcribing_started_at") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN transcribing_started_at INTEGER;")
        }
        // Two-tier usage class for the meeting: "advanced" = a cloud
        // model billed for compute (Gemini / Whisper-cloud), "local" =
        // on-device WhisperKit (zero cost). `nil` for legacy rows; the
        // /api/usage aggregator treats null as advanced for safety
        // (better to over-count than to silently free-tier billable
        // calls) but stops at `transcribed_at IS NOT NULL` so unread
        // legacy rows don't double-count.
        m.registerMigration("v18_transcription_class") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN transcription_class TEXT;")
        }
        // Auto-chapters: a JSON-encoded array of
        // `{ "start_ms": Int64, "title": String }`, rendered as a
        // third tab in MeetingView next to Transcript / Summary.
        // Generated by GeminiChapters after auto-summary lands.
        m.registerMigration("v19_chapters") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN chapters TEXT;")
        }

        // Bounded launch-time auto-retry of failed transcriptions.
        m.registerMigration("v20_transcribe_attempts") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN transcribe_attempts INTEGER NOT NULL DEFAULT 0;")
        }

        // Index speakers by meeting so the per-row speaker_names subquery
        // in listMeetingSummaries (+ speaker merge/reassign) stops full-
        // scanning the speakers table. Pure perf — no behaviour change.
        m.registerMigration("v21_speakers_meeting_index") { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_speakers_meeting ON speakers(meeting_id);")
        }

        // Index segments by speaker so the hot per-speaker queries (merge,
        // reassign, orphan-speaker purge, and the listMeetingSummaries preview
        // subquery) stop full-scanning the segments table on a large library.
        // Pure perf — no behaviour change (mirrors v21). idx_segments_meeting_start
        // already covers meeting_id, but not speaker_id.
        m.registerMigration("v22_segments_speaker_index") { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_segments_speaker ON segments(speaker_id);")
        }

        // Human-readable on-disk folder name for a recording (e.g.
        // "2026-07-07_10-19 Sync with team"). NULL means the folder is still the
        // legacy/plain `<meeting-id>` (the fallback AppPaths resolves to). Set
        // when the auto-title lands (RecordingDirNaming.renameToTitled) and by
        // the one-time launch migration that renames existing folders.
        m.registerMigration("v23_dir_name") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN dir_name TEXT;")
        }

        return m
    }
}
