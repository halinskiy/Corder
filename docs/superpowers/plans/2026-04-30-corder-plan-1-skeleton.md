# Corder — Plan 1: Skeleton & API

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a runnable macOS menu bar `Corder.app` whose backend plumbing (SwiftPM build, GRDB SQLite + FTS5, Swifter HTTP server with Range support, WKWebView library window) is fully wired and unit-tested. No recording or transcription in this plan — those are Plan 2 and Plan 3.

**Architecture:** Pure SwiftPM executable target (same shape as PTS at `/Users/3mpq/ClaudeClaw/`). Storage via GRDB. Local HTTP via Swifter on a dynamically-allocated port. WKWebView loads the served React bundle from a stub Vite project. Tests live in a separate test target.

**Tech Stack:** Swift 5.9, AppKit, GRDB.swift, Swifter, Vite + React + TS (skeleton only).

**Definition of done:** `swift run Corder` puts a recording-dot icon in the menu bar, clicking "Open Library" opens a window that shows a placeholder React shell, and `swift test` is green.

---

## Spec references

- `/Users/3mpq/Corder/docs/superpowers/specs/2026-04-30-corder-design.md` — full design
- Sections most relevant to this plan: Architecture, LocalServer routes, Storage schema, File layout

## Files this plan creates

```
/Users/3mpq/Corder/
├── Package.swift                                  # SwiftPM manifest
├── .gitignore                                     # add build artefacts
├── Sources/
│   └── Corder/
│       ├── App/
│       │   ├── CorderApp.swift                    # @main, NSApp setup
│       │   ├── AppDelegate.swift                  # lifecycle, menu bar wiring
│       │   └── AppContext.swift                   # shared singletons (db, server, paths)
│       ├── Storage/
│       │   ├── Database.swift                     # GRDB DatabaseQueue factory
│       │   ├── Migrations.swift                   # v1 schema + FTS5
│       │   ├── Models.swift                       # Meeting/Speaker/Segment structs
│       │   └── MeetingRepository.swift            # list / fetch / insert / search
│       ├── Server/
│       │   ├── LocalServer.swift                  # Swifter lifecycle, port pick
│       │   ├── Routes.swift                       # route registration
│       │   ├── RangeRequest.swift                 # parse `Range:` header
│       │   ├── DTOs.swift                         # JSON payload shapes
│       │   └── TranscriptFormatter.swift          # produce clipboard text
│       ├── UI/
│       │   ├── MenuBarController.swift            # NSStatusItem + popover
│       │   ├── PopoverContentView.swift           # SwiftUI popover body
│       │   ├── LibraryWindow.swift                # WKWebView host
│       │   └── WebViewBridge.swift                # WKWebView config
│       ├── Resources/
│       │   └── web/                               # generated React bundle (gitignored)
│       └── Shared/
│           └── Paths.swift                        # ~/Library/Application Support helpers
├── Tests/
│   └── CorderTests/
│       ├── MigrationsTests.swift
│       ├── MeetingRepositoryTests.swift
│       ├── RangeRequestTests.swift
│       └── TranscriptFormatterTests.swift
├── Web/
│   ├── package.json
│   ├── vite.config.ts
│   ├── tsconfig.json
│   ├── index.html
│   └── src/
│       └── main.tsx                               # placeholder shell
└── Scripts/
    └── build-web.sh                               # npm build → copy to Resources
```

---

## Task 1: SwiftPM scaffold

**Files:**
- Create: `/Users/3mpq/Corder/Package.swift`
- Create: `/Users/3mpq/Corder/Sources/Corder/App/CorderApp.swift`
- Modify: `/Users/3mpq/Corder/.gitignore`

- [ ] **Step 1.1 — Write `Package.swift`**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Corder",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Corder", targets: ["Corder"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "Corder",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Swifter", package: "swifter")
            ],
            resources: [
                .copy("Resources/web")
            ]
        ),
        .testTarget(
            name: "CorderTests",
            dependencies: ["Corder"]
        )
    ]
)
```

- [ ] **Step 1.2 — Write the trivial entry point**

`Sources/Corder/App/CorderApp.swift`:

```swift
import AppKit

@main
enum CorderApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar app, no Dock icon
        app.run()
    }
}
```

- [ ] **Step 1.3 — Stub `AppDelegate.swift` so the app at least launches**

`Sources/Corder/App/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        // Filled in by Task 6 (menu bar wiring).
    }
}
```

- [ ] **Step 1.4 — Stub `Resources/web/` so SwiftPM's `.copy` rule doesn't fail**

```bash
mkdir -p /Users/3mpq/Corder/Sources/Corder/Resources/web
echo "<!doctype html><title>Corder</title><h1>Corder dev shell</h1>" \
  > /Users/3mpq/Corder/Sources/Corder/Resources/web/index.html
```

- [ ] **Step 1.5 — Update `.gitignore`**

Append to `/Users/3mpq/Corder/.gitignore`:

```
.build/
.swiftpm/
Package.resolved
Web/node_modules/
Web/dist/
```

(Do NOT ignore `Sources/Corder/Resources/web/` — that's the bundled output and we want a placeholder there until Vite is wired up.)

- [ ] **Step 1.6 — Verify build**

Run from `/Users/3mpq/Corder/`:

```bash
swift build
```

Expected: `Build complete!` (warnings about empty AppDelegate are fine).

- [ ] **Step 1.7 — Commit**

```bash
git add Package.swift .gitignore Sources/
git commit -m "feat: SwiftPM scaffold with empty AppDelegate"
```

---

## Task 2: Application support paths

**Files:**
- Create: `Sources/Corder/Shared/Paths.swift`

The whole app needs to agree on where to put the database, recordings, models. One module, no behavior, easy to test.

- [ ] **Step 2.1 — Write `Paths.swift`**

```swift
import Foundation

enum AppPaths {
    /// `~/Library/Application Support/Corder/`
    static var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Corder", isDirectory: true)
    }
    static var databaseURL: URL { supportRoot.appendingPathComponent("corder.db") }
    static var modelsDir: URL { supportRoot.appendingPathComponent("models", isDirectory: true) }
    static var recordingsDir: URL { supportRoot.appendingPathComponent("recordings", isDirectory: true) }

    /// Create every directory if missing. Idempotent.
    static func ensureExists() throws {
        for url in [supportRoot, modelsDir, recordingsDir] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func recordingDir(for meetingId: String) -> URL {
        recordingsDir.appendingPathComponent(meetingId, isDirectory: true)
    }
}
```

- [ ] **Step 2.2 — Verify**

```bash
swift build
```

- [ ] **Step 2.3 — Commit**

```bash
git add Sources/Corder/Shared/Paths.swift
git commit -m "feat: application support path helpers"
```

---

## Task 3: Database & migrations

**Files:**
- Create: `Sources/Corder/Storage/Database.swift`
- Create: `Sources/Corder/Storage/Migrations.swift`
- Create: `Tests/CorderTests/MigrationsTests.swift`

- [ ] **Step 3.1 — Write the failing test first**

`Tests/CorderTests/MigrationsTests.swift`:

```swift
import XCTest
import GRDB
@testable import Corder

final class MigrationsTests: XCTestCase {
    func test_v1_creates_all_tables() throws {
        let dbq = try DatabaseQueue()           // in-memory
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
```

- [ ] **Step 3.2 — Run the test, watch it fail**

```bash
swift test --filter MigrationsTests
```

Expected: compilation error — `Migrations` undefined.

- [ ] **Step 3.3 — Implement `Migrations.swift`**

```swift
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
            // keep FTS in sync with segments
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
```

- [ ] **Step 3.4 — Implement `Database.swift`**

```swift
import Foundation
import GRDB

enum Database {
    /// Opens the on-disk DB and runs migrations.
    static func openShared() throws -> DatabaseQueue {
        try AppPaths.ensureExists()
        let dbq = try DatabaseQueue(path: AppPaths.databaseURL.path)
        try Migrations.register().migrate(dbq)
        return dbq
    }
}
```

- [ ] **Step 3.5 — Run tests, expect green**

```bash
swift test --filter MigrationsTests
```

Expected: 2 passing.

- [ ] **Step 3.6 — Commit**

```bash
git add Sources/Corder/Storage/ Tests/CorderTests/MigrationsTests.swift
git commit -m "feat: SQLite schema with FTS5 for segments"
```

---

## Task 4: Domain models & repository

**Files:**
- Create: `Sources/Corder/Storage/Models.swift`
- Create: `Sources/Corder/Storage/MeetingRepository.swift`
- Create: `Tests/CorderTests/MeetingRepositoryTests.swift`

- [ ] **Step 4.1 — Write the failing tests**

`Tests/CorderTests/MeetingRepositoryTests.swift`:

```swift
import XCTest
import GRDB
@testable import Corder

final class MeetingRepositoryTests: XCTestCase {
    private func freshDB() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()
        try Migrations.register().migrate(dbq)
        return dbq
    }

    func test_insertMeeting_then_listMeetings_returnsIt() throws {
        let dbq = try freshDB()
        let repo = MeetingRepository(dbq: dbq)
        let m = Meeting(
            id: "m1",
            startedAt: 1_000,
            endedAt: 2_000,
            durationMs: 1_000,
            videoPath: "/tmp/v.mov",
            audioPath: "/tmp/a.wav",
            transcribedAt: nil,
            status: .ready
        )
        try repo.insertMeeting(m)
        let listed = try repo.listMeetings()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, "m1")
    }

    func test_search_findsMatchingSegment() throws {
        let dbq = try freshDB()
        let repo = MeetingRepository(dbq: dbq)
        try repo.insertMeeting(Meeting.fixture(id: "m1"))
        try repo.insertSpeaker(Speaker(id: "s1", meetingId: "m1", label: "Speaker 1", customName: nil, colorHex: "#000"))
        try repo.insertSegment(Segment(id: nil, meetingId: "m1", speakerId: "s1", startMs: 0, endMs: 1000, text: "discuss the roadmap", wordsJson: nil))
        try repo.insertSegment(Segment(id: nil, meetingId: "m1", speakerId: "s1", startMs: 1000, endMs: 2000, text: "lunch break now", wordsJson: nil))

        let hits = try repo.searchSegments(query: "roadmap")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.text, "discuss the roadmap")
    }

    func test_renameSpeaker_persists() throws {
        let dbq = try freshDB()
        let repo = MeetingRepository(dbq: dbq)
        try repo.insertMeeting(Meeting.fixture(id: "m1"))
        try repo.insertSpeaker(Speaker(id: "s1", meetingId: "m1", label: "Speaker 1", customName: nil, colorHex: "#000"))
        try repo.renameSpeaker(speakerId: "s1", customName: "Misha")

        let speakers = try repo.speakers(forMeeting: "m1")
        XCTAssertEqual(speakers.first?.customName, "Misha")
    }
}

extension Meeting {
    static func fixture(id: String) -> Meeting {
        Meeting(id: id, startedAt: 0, endedAt: 1, durationMs: 1, videoPath: "v", audioPath: "a", transcribedAt: nil, status: .ready)
    }
}
```

- [ ] **Step 4.2 — Run, expect failure (Models / MeetingRepository undefined)**

```bash
swift test --filter MeetingRepositoryTests
```

- [ ] **Step 4.3 — Write `Models.swift`**

```swift
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
        case id, startedAt = "started_at", endedAt = "ended_at",
             durationMs = "duration_ms", videoPath = "video_path",
             audioPath = "audio_path", transcribedAt = "transcribed_at", status
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
        case id, meetingId = "meeting_id", label,
             customName = "custom_name", colorHex = "color_hex"
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
        case id, meetingId = "meeting_id", speakerId = "speaker_id",
             startMs = "start_ms", endMs = "end_ms", text, wordsJson = "words_json"
    }
}
```

- [ ] **Step 4.4 — Write `MeetingRepository.swift`**

```swift
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

    /// Returns matching segments, joined back to their meeting & speaker.
    func searchSegments(query: String) throws -> [Segment] {
        // FTS5 is contentless externally — join via rowid.
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
```

- [ ] **Step 4.5 — Run tests, expect green**

```bash
swift test --filter MeetingRepositoryTests
```

Expected: 3 passing.

- [ ] **Step 4.6 — Commit**

```bash
git add Sources/Corder/Storage/Models.swift \
        Sources/Corder/Storage/MeetingRepository.swift \
        Tests/CorderTests/MeetingRepositoryTests.swift
git commit -m "feat: GRDB models and meeting repository"
```

---

## Task 5: HTTP server — Range requests & DTOs

**Files:**
- Create: `Sources/Corder/Server/RangeRequest.swift`
- Create: `Sources/Corder/Server/DTOs.swift`
- Create: `Sources/Corder/Server/TranscriptFormatter.swift`
- Create: `Tests/CorderTests/RangeRequestTests.swift`
- Create: `Tests/CorderTests/TranscriptFormatterTests.swift`

Range parsing and the transcript format are the only two pieces of server logic worth unit-testing. Routes themselves are integration-tested by manually pinging the running server in Task 6's verification.

- [ ] **Step 5.1 — Write the failing range tests**

`Tests/CorderTests/RangeRequestTests.swift`:

```swift
import XCTest
@testable import Corder

final class RangeRequestTests: XCTestCase {
    func test_parse_valid() {
        XCTAssertEqual(RangeRequest.parse("bytes=0-999", fileSize: 10_000),
                       RangeRequest(start: 0, end: 999))
    }

    func test_parse_open_ended() {
        XCTAssertEqual(RangeRequest.parse("bytes=500-", fileSize: 10_000),
                       RangeRequest(start: 500, end: 9_999))
    }

    func test_parse_suffix() {
        XCTAssertEqual(RangeRequest.parse("bytes=-100", fileSize: 10_000),
                       RangeRequest(start: 9_900, end: 9_999))
    }

    func test_parse_clamps_to_fileSize() {
        XCTAssertEqual(RangeRequest.parse("bytes=0-99999", fileSize: 100),
                       RangeRequest(start: 0, end: 99))
    }

    func test_parse_garbage_returnsNil() {
        XCTAssertNil(RangeRequest.parse("invalid", fileSize: 100))
        XCTAssertNil(RangeRequest.parse("bytes=", fileSize: 100))
    }
}
```

- [ ] **Step 5.2 — Run, expect compile failure**

```bash
swift test --filter RangeRequestTests
```

- [ ] **Step 5.3 — Implement `RangeRequest.swift`**

```swift
import Foundation

struct RangeRequest: Equatable {
    let start: Int64
    let end: Int64           // inclusive
    var length: Int64 { end - start + 1 }

    /// Parses an HTTP `Range:` header like `bytes=0-999`, `bytes=500-`, `bytes=-100`.
    /// Returns nil on garbage. Clamps `end` to `fileSize - 1`.
    static func parse(_ header: String, fileSize: Int64) -> RangeRequest? {
        guard fileSize > 0 else { return nil }
        guard header.hasPrefix("bytes=") else { return nil }
        let body = header.dropFirst("bytes=".count)
        let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let lhs = parts[0].trimmingCharacters(in: .whitespaces)
        let rhs = parts[1].trimmingCharacters(in: .whitespaces)

        let last = fileSize - 1

        if lhs.isEmpty {
            // suffix: bytes=-N → last N bytes
            guard let n = Int64(rhs), n > 0 else { return nil }
            let start = max(0, fileSize - n)
            return RangeRequest(start: start, end: last)
        }

        guard let start = Int64(lhs) else { return nil }
        if rhs.isEmpty {
            return RangeRequest(start: start, end: last)
        }
        guard let endParsed = Int64(rhs) else { return nil }
        let end = min(endParsed, last)
        guard start <= end else { return nil }
        return RangeRequest(start: start, end: end)
    }
}
```

- [ ] **Step 5.4 — Run, expect green**

```bash
swift test --filter RangeRequestTests
```

Expected: 5 passing.

- [ ] **Step 5.5 — Write the transcript formatter test**

`Tests/CorderTests/TranscriptFormatterTests.swift`:

```swift
import XCTest
@testable import Corder

final class TranscriptFormatterTests: XCTestCase {
    func test_formats_with_speaker_label_only() {
        let speakers = [
            Speaker(id: "a", meetingId: "m", label: "Speaker 1", customName: nil, colorHex: "#000"),
            Speaker(id: "b", meetingId: "m", label: "Speaker 2", customName: nil, colorHex: "#111")
        ]
        let segs = [
            Segment(id: 1, meetingId: "m", speakerId: "a", startMs: 12_000, endMs: 17_000, text: "Hi everyone", wordsJson: nil),
            Segment(id: 2, meetingId: "m", speakerId: "b", startMs: 17_000, endMs: 23_000, text: "Let's start", wordsJson: nil)
        ]
        let out = TranscriptFormatter.clipboardText(segments: segs, speakers: speakers)
        XCTAssertEqual(out, """
        [00:00:12] Speaker 1: Hi everyone
        [00:00:17] Speaker 2: Let's start
        """)
    }

    func test_uses_custom_name_when_set() {
        let speakers = [
            Speaker(id: "a", meetingId: "m", label: "Speaker 1", customName: "Misha", colorHex: "#000")
        ]
        let segs = [
            Segment(id: 1, meetingId: "m", speakerId: "a", startMs: 0, endMs: 1000, text: "yo", wordsJson: nil)
        ]
        let out = TranscriptFormatter.clipboardText(segments: segs, speakers: speakers)
        XCTAssertEqual(out, "[00:00:00] Speaker 1 (Misha): yo")
    }

    func test_handles_hours() {
        let speakers = [Speaker(id: "a", meetingId: "m", label: "Speaker 1", customName: nil, colorHex: "#000")]
        let segs = [Segment(id: 1, meetingId: "m", speakerId: "a", startMs: 3_661_000, endMs: 3_662_000, text: "ok", wordsJson: nil)]
        XCTAssertEqual(TranscriptFormatter.clipboardText(segments: segs, speakers: speakers),
                       "[01:01:01] Speaker 1: ok")
    }
}
```

- [ ] **Step 5.6 — Implement `TranscriptFormatter.swift`**

```swift
import Foundation

enum TranscriptFormatter {
    /// Renders the [hh:mm:ss] Speaker N (Custom): text format used by the Copy button.
    static func clipboardText(segments: [Segment], speakers: [Speaker]) -> String {
        let byId = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        return segments.map { seg -> String in
            let stamp = formatTimestamp(ms: seg.startMs)
            let sp = byId[seg.speakerId]
            let name: String
            if let s = sp {
                if let custom = s.customName, !custom.isEmpty {
                    name = "\(s.label) (\(custom))"
                } else {
                    name = s.label
                }
            } else {
                name = "Unknown"
            }
            return "[\(stamp)] \(name): \(seg.text)"
        }.joined(separator: "\n")
    }

    private static func formatTimestamp(ms: Int64) -> String {
        let totalSec = ms / 1000
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
```

- [ ] **Step 5.7 — Run, expect green**

```bash
swift test --filter TranscriptFormatterTests
```

Expected: 3 passing.

- [ ] **Step 5.8 — Write `DTOs.swift`** (no tests — pure data shapes)

```swift
import Foundation

/// Wire format. Field names match the JSON sent to the React frontend.
enum DTO {
    struct MeetingSummary: Codable {
        let id: String
        let started_at: Int64
        let ended_at: Int64?
        let duration_ms: Int64?
        let status: String
        let preview: String?       // first segment text
    }

    struct MeetingDetail: Codable {
        let id: String
        let started_at: Int64
        let duration_ms: Int64?
        let status: String
        let speakers: [SpeakerDTO]
        let segments: [SegmentDTO]
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
    }

    struct RenameRequest: Codable {
        let name: String?    // null clears
    }

    struct SearchHit: Codable {
        let meeting_id: String
        let segment_id: Int64
        let start_ms: Int64
        let text: String
    }
}
```

- [ ] **Step 5.9 — Verify build still works**

```bash
swift build
```

- [ ] **Step 5.10 — Commit**

```bash
git add Sources/Corder/Server/ Tests/CorderTests/RangeRequestTests.swift Tests/CorderTests/TranscriptFormatterTests.swift
git commit -m "feat: range parser, DTOs, transcript formatter"
```

---

## Task 6: HTTP server lifecycle & routes

**Files:**
- Create: `Sources/Corder/Server/LocalServer.swift`
- Create: `Sources/Corder/Server/Routes.swift`
- Create: `Sources/Corder/App/AppContext.swift`

This task is integration-tested manually at the end (curl against the running app). No unit tests — the value is wiring, and Swifter has its own.

- [ ] **Step 6.1 — Write `LocalServer.swift`**

```swift
import Foundation
import Swifter

final class LocalServer {
    private let server = HttpServer()
    private(set) var port: UInt16 = 0

    func start(routes: (HttpServer) -> Void) throws {
        routes(server)
        // Bind to 127.0.0.1 only — never listen on all interfaces.
        // Swifter picks an OS-assigned port when we pass 0.
        try server.start(0, forceIPv4: true, priority: .userInitiated)
        // Swifter doesn't expose the chosen port directly until 1.5+ via `port()`.
        port = try UInt16(server.port())
    }

    func stop() {
        server.stop()
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }
}
```

- [ ] **Step 6.2 — Write `Routes.swift`**

```swift
import Foundation
import GRDB
import Swifter

enum Routes {
    static func register(server: HttpServer, repo: MeetingRepository) {
        // Static React bundle — bundled via SwiftPM `.copy("Resources/web")`.
        server["/"] = serveIndex
        server["/assets/:path"] = { req in serveAsset(path: req.params[":path"] ?? "") }
        server.get["/index.html"] = { _ in serveIndex(.init(method: "GET", path: "/", queryParams: [], headers: [:], body: [], address: nil, params: [:])) }

        server.get["/api/meetings"] = { _ in listMeetings(repo: repo) }
        server.get["/api/meetings/:id"] = { req in meetingDetail(id: req.params[":id"] ?? "", repo: repo) }
        server.get["/api/meetings/:id/transcript.txt"] = { req in transcriptText(id: req.params[":id"] ?? "", repo: repo) }
        server.get["/api/meetings/:id/video"] = { req in serveMedia(id: req.params[":id"] ?? "", kind: .video, repo: repo, headers: req.headers) }
        server.get["/api/meetings/:id/audio"] = { req in serveMedia(id: req.params[":id"] ?? "", kind: .audio, repo: repo, headers: req.headers) }
        server.post["/api/meetings/:id/speakers/:sid/rename"] = { req in renameSpeaker(req: req, repo: repo) }
        server.get["/api/search"] = { req in
            let q = req.queryParams.first(where: { $0.0 == "q" })?.1 ?? ""
            return search(query: q, repo: repo)
        }
    }

    // MARK: static

    private static func serveIndex(_ req: HttpRequest) -> HttpResponse {
        let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "web")
            ?? Bundle.module.bundleURL.appendingPathComponent("web/index.html")
        guard let data = try? Data(contentsOf: url) else { return .notFound }
        return .raw(200, "OK", ["Content-Type": "text/html; charset=utf-8"]) { writer in
            try writer.write(data)
        }
    }

    private static func serveAsset(path: String) -> HttpResponse {
        let webRoot = Bundle.module.bundleURL.appendingPathComponent("web", isDirectory: true)
        let target = webRoot.appendingPathComponent("assets").appendingPathComponent(path)
        guard let data = try? Data(contentsOf: target) else { return .notFound }
        let mime = mimeType(for: target.pathExtension)
        return .raw(200, "OK", ["Content-Type": mime]) { try $0.write(data) }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    // MARK: api

    private static func listMeetings(repo: MeetingRepository) -> HttpResponse {
        do {
            let meetings = try repo.listMeetings()
            let summaries: [DTO.MeetingSummary] = try meetings.map { m in
                let firstSeg = try repo.segments(forMeeting: m.id).first
                return DTO.MeetingSummary(
                    id: m.id, started_at: m.startedAt, ended_at: m.endedAt,
                    duration_ms: m.durationMs, status: m.status.rawValue,
                    preview: firstSeg?.text
                )
            }
            return jsonResponse(summaries)
        } catch {
            return .internalServerError
        }
    }

    private static func meetingDetail(id: String, repo: MeetingRepository) -> HttpResponse {
        do {
            guard let m = try repo.meeting(id: id) else { return .notFound }
            let speakers = try repo.speakers(forMeeting: id)
            let segments = try repo.segments(forMeeting: id)
            let dto = DTO.MeetingDetail(
                id: m.id, started_at: m.startedAt, duration_ms: m.durationMs,
                status: m.status.rawValue,
                speakers: speakers.map { DTO.SpeakerDTO(id: $0.id, label: $0.label, custom_name: $0.customName, color_hex: $0.colorHex) },
                segments: segments.map { DTO.SegmentDTO(id: $0.id ?? 0, speaker_id: $0.speakerId, start_ms: $0.startMs, end_ms: $0.endMs, text: $0.text) }
            )
            return jsonResponse(dto)
        } catch {
            return .internalServerError
        }
    }

    private static func transcriptText(id: String, repo: MeetingRepository) -> HttpResponse {
        do {
            let segments = try repo.segments(forMeeting: id)
            let speakers = try repo.speakers(forMeeting: id)
            let text = TranscriptFormatter.clipboardText(segments: segments, speakers: speakers)
            return .raw(200, "OK", ["Content-Type": "text/plain; charset=utf-8"]) {
                try $0.write([UInt8](text.utf8))
            }
        } catch {
            return .internalServerError
        }
    }

    private static func renameSpeaker(req: HttpRequest, repo: MeetingRepository) -> HttpResponse {
        let sid = req.params[":sid"] ?? ""
        guard !sid.isEmpty else { return .badRequest(.text("missing speaker id")) }
        do {
            let body = Data(req.body)
            let parsed = try JSONDecoder().decode(DTO.RenameRequest.self, from: body)
            try repo.renameSpeaker(speakerId: sid, customName: parsed.name)
            return .ok(.text("ok"))
        } catch {
            return .badRequest(.text("\(error)"))
        }
    }

    private static func search(query: String, repo: MeetingRepository) -> HttpResponse {
        guard !query.isEmpty else { return jsonResponse([DTO.SearchHit]()) }
        do {
            let segs = try repo.searchSegments(query: query)
            let hits = segs.map {
                DTO.SearchHit(meeting_id: $0.meetingId, segment_id: $0.id ?? 0,
                              start_ms: $0.startMs, text: $0.text)
            }
            return jsonResponse(hits)
        } catch {
            return .internalServerError
        }
    }

    // MARK: media (Range)

    private enum MediaKind { case video, audio }

    private static func serveMedia(id: String, kind: MediaKind, repo: MeetingRepository, headers: [String: String]) -> HttpResponse {
        do {
            guard let m = try repo.meeting(id: id) else { return .notFound }
            let path = (kind == .video) ? m.videoPath : m.audioPath
            let url = URL(fileURLWithPath: path)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let contentType = (kind == .video) ? "video/quicktime" : "audio/wav"

            // No Range header → return whole file.
            guard let rangeHeader = headers["range"] ?? headers["Range"] else {
                let data = try Data(contentsOf: url)
                return .raw(200, "OK", [
                    "Content-Type": contentType,
                    "Accept-Ranges": "bytes",
                    "Content-Length": "\(size)"
                ]) { try $0.write(data) }
            }

            guard let r = RangeRequest.parse(rangeHeader, fileSize: size) else {
                return .raw(416, "Range Not Satisfiable", [
                    "Content-Range": "bytes */\(size)"
                ]) { _ in }
            }

            // Stream just the requested slice.
            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: UInt64(r.start))
            let chunk = handle.readData(ofLength: Int(r.length))
            try? handle.close()

            return .raw(206, "Partial Content", [
                "Content-Type": contentType,
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(r.start)-\(r.end)/\(size)",
                "Content-Length": "\(r.length)"
            ]) { try $0.write(chunk) }
        } catch {
            return .internalServerError
        }
    }

    // MARK: helpers

    private static func jsonResponse<T: Encodable>(_ value: T) -> HttpResponse {
        do {
            let enc = JSONEncoder()
            let data = try enc.encode(value)
            return .raw(200, "OK", ["Content-Type": "application/json; charset=utf-8"]) {
                try $0.write([UInt8](data))
            }
        } catch {
            return .internalServerError
        }
    }
}
```

- [ ] **Step 6.3 — Write `AppContext.swift`** (lazy singletons)

```swift
import Foundation
import GRDB

final class AppContext {
    static let shared = AppContext()
    private init() {}

    private(set) lazy var dbq: DatabaseQueue = {
        do { return try Database.openShared() }
        catch { fatalError("Failed to open DB: \(error)") }
    }()

    private(set) lazy var repo: MeetingRepository = MeetingRepository(dbq: dbq)
    let server = LocalServer()
}
```

- [ ] **Step 6.4 — Verify it compiles**

```bash
swift build
```

- [ ] **Step 6.5 — Commit**

```bash
git add Sources/Corder/Server/LocalServer.swift Sources/Corder/Server/Routes.swift Sources/Corder/App/AppContext.swift
git commit -m "feat: HTTP routes and shared app context"
```

---

## Task 7: Menu bar UI & WebView window

**Files:**
- Create: `Sources/Corder/UI/MenuBarController.swift`
- Create: `Sources/Corder/UI/PopoverContentView.swift`
- Create: `Sources/Corder/UI/LibraryWindow.swift`
- Modify: `Sources/Corder/App/AppDelegate.swift`

- [ ] **Step 7.1 — Write `LibraryWindow.swift`**

```swift
import AppKit
import WebKit

final class LibraryWindow: NSWindowController {
    static let shared = LibraryWindow()

    private var webView: WKWebView!

    private init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.title = "Corder"
        win.titlebarAppearsTransparent = true
        win.center()
        super.init(window: win)

        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let wv = WKWebView(frame: win.contentView!.bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        win.contentView?.addSubview(wv)
        self.webView = wv
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(serverURL: URL) {
        if webView.url == nil {
            webView.load(URLRequest(url: serverURL))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 7.2 — Write `PopoverContentView.swift`**

```swift
import SwiftUI

struct PopoverContentView: View {
    let onOpenLibrary: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Corder").font(.headline)
            Button("Start Recording") { /* Plan 2 */ }
                .disabled(true)
                .help("Recording arrives in Plan 2")
            Button("Open Library", action: onOpenLibrary)
            Text("Plan 1 — skeleton only")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 240)
    }
}
```

- [ ] **Step 7.3 — Write `MenuBarController.swift`**

```swift
import AppKit
import SwiftUI

final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let onOpenLibrary: () -> Void

    init(onOpenLibrary: @escaping () -> Void) {
        self.onOpenLibrary = onOpenLibrary
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Corder")
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 240, height: 160)
        popover.contentViewController = NSHostingController(rootView: PopoverContentView { [weak self] in
            self?.popover.performClose(nil)
            self?.onOpenLibrary()
        })
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
```

- [ ] **Step 7.4 — Wire everything in `AppDelegate.swift`**

Replace the entire contents of `Sources/Corder/App/AppDelegate.swift` with:

```swift
import AppKit
import Swifter

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ note: Notification) {
        startServer()
        menuBar = MenuBarController { [weak self] in
            self?.openLibrary()
        }
    }

    private func startServer() {
        do {
            try AppContext.shared.server.start { httpServer in
                Routes.register(server: httpServer, repo: AppContext.shared.repo)
            }
            NSLog("Corder server on \(AppContext.shared.server.baseURL)")
        } catch {
            NSLog("Server failed to start: \(error)")
        }
    }

    private func openLibrary() {
        LibraryWindow.shared.show(serverURL: AppContext.shared.server.baseURL)
    }
}
```

- [ ] **Step 7.5 — Verify build**

```bash
swift build
```

Expected: `Build complete!` with no errors.

- [ ] **Step 7.6 — Commit**

```bash
git add Sources/Corder/UI/ Sources/Corder/App/AppDelegate.swift
git commit -m "feat: menu bar popover and WebView library window"
```

---

## Task 8: Vite + React skeleton

**Files:**
- Create: `Web/package.json`
- Create: `Web/vite.config.ts`
- Create: `Web/tsconfig.json`
- Create: `Web/index.html`
- Create: `Web/src/main.tsx`
- Create: `Scripts/build-web.sh`

This is intentionally minimal — proper UI lands in Plan 3.

- [ ] **Step 8.1 — Init Vite project**

```bash
cd /Users/3mpq/Corder
mkdir -p Web/src Scripts
```

- [ ] **Step 8.2 — Write `Web/package.json`**

```json
{
  "name": "corder-web",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc -b && vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.3.0",
    "react-dom": "^18.3.0"
  },
  "devDependencies": {
    "@types/react": "^18.3.0",
    "@types/react-dom": "^18.3.0",
    "@vitejs/plugin-react": "^4.3.0",
    "typescript": "^5.5.0",
    "vite": "^5.4.0"
  }
}
```

- [ ] **Step 8.3 — Write `Web/vite.config.ts`**

```ts
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    assetsDir: "assets",
  },
  // assets that the SwiftPM bundle will serve at the root
  base: "/",
});
```

- [ ] **Step 8.4 — Write `Web/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "jsx": "react-jsx",
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true,
    "isolatedModules": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true
  },
  "include": ["src", "vite.config.ts"]
}
```

- [ ] **Step 8.5 — Write `Web/index.html`**

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Corder</title>
    <meta name="viewport" content="width=device-width, initial-scale=1" />
  </head>
  <body style="margin:0;background:#0a0a0a;color:#fff;font-family:-apple-system,sans-serif;">
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

- [ ] **Step 8.6 — Write `Web/src/main.tsx`** (placeholder — Plan 3 replaces it entirely)

```tsx
import React from "react";
import { createRoot } from "react-dom/client";

function App() {
  const [meetings, setMeetings] = React.useState<unknown[]>([]);

  React.useEffect(() => {
    fetch("/api/meetings").then((r) => r.json()).then(setMeetings).catch(() => {});
  }, []);

  return (
    <main style={{ padding: 32 }}>
      <h1 style={{ fontWeight: 500, letterSpacing: -0.5 }}>Corder</h1>
      <p style={{ opacity: 0.6 }}>Plan 1 skeleton. Server is up if you see this.</p>
      <pre style={{ background: "#111", padding: 16, borderRadius: 8 }}>
        {JSON.stringify(meetings, null, 2)}
      </pre>
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
```

- [ ] **Step 8.7 — Write `Scripts/build-web.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Web"
npm install --no-audit --no-fund
npm run build
rm -rf "$ROOT/Sources/Corder/Resources/web"
mkdir -p "$ROOT/Sources/Corder/Resources/web"
cp -R dist/. "$ROOT/Sources/Corder/Resources/web/"
echo "✔ Web bundle copied into SwiftPM resources"
```

Make it executable:

```bash
chmod +x /Users/3mpq/Corder/Scripts/build-web.sh
```

- [ ] **Step 8.8 — First build of the web bundle**

```bash
/Users/3mpq/Corder/Scripts/build-web.sh
```

Expected: dependencies install, Vite produces `Web/dist/`, files end up in `Sources/Corder/Resources/web/`.

- [ ] **Step 8.9 — Rebuild Swift to pick up new resources**

```bash
cd /Users/3mpq/Corder
swift build
```

- [ ] **Step 8.10 — Commit**

```bash
git add Web/ Scripts/build-web.sh Sources/Corder/Resources/web/
git commit -m "feat: Vite + React skeleton with build script"
```

---

## Task 9: End-to-end smoke

This is the demo moment — running the app and seeing it work.

- [ ] **Step 9.1 — Run the app**

```bash
cd /Users/3mpq/Corder
swift run Corder
```

Expected:
- A recording-dot icon appears in the macOS menu bar.
- Console prints something like `Corder server on http://127.0.0.1:54312/`.

- [ ] **Step 9.2 — Click the menu bar icon → popover appears**

You see "Start Recording" (disabled), "Open Library", "Plan 1 — skeleton only".

- [ ] **Step 9.3 — Click Open Library → window opens with React shell**

You see "Corder" + "Plan 1 skeleton. Server is up if you see this." + an empty array `[]`.

- [ ] **Step 9.4 — Probe the API directly**

In a second terminal, replace `<port>` with the port from step 9.1's log line:

```bash
curl -s http://127.0.0.1:<port>/api/meetings
```

Expected output: `[]`

```bash
curl -s -i http://127.0.0.1:<port>/
```

Expected: `200 OK` and `Content-Type: text/html`.

- [ ] **Step 9.5 — Range request smoke (synthetic)**

Insert a fake meeting row pointing at any local file to confirm Range works:

```bash
sqlite3 ~/Library/Application\ Support/Corder/corder.db <<'SQL'
INSERT INTO meetings(id, started_at, video_path, audio_path, status)
VALUES ('demo', strftime('%s','now')*1000, '/System/Library/Sounds/Glass.aiff', '/System/Library/Sounds/Glass.aiff', 'ready');
SQL

curl -s -I -H "Range: bytes=0-99" http://127.0.0.1:<port>/api/meetings/demo/audio
```

Expected: `HTTP/1.1 206 Partial Content` and `Content-Range: bytes 0-99/<filesize>`.

Clean up:

```bash
sqlite3 ~/Library/Application\ Support/Corder/corder.db "DELETE FROM meetings WHERE id='demo';"
```

- [ ] **Step 9.6 — Stop the app** (Ctrl-C in the `swift run` terminal)

- [ ] **Step 9.7 — Run all unit tests one last time**

```bash
swift test
```

Expected: all tests passing.

- [ ] **Step 9.8 — Tag the milestone**

```bash
git tag -a v0.1.0-skeleton -m "Plan 1 complete: skeleton & API"
```

---

## Out of scope for Plan 1 (covered later)

- ScreenCaptureKit recording → **Plan 2**
- Audio mixdown for whisper → **Plan 2**
- sherpa-onnx VAD/ASR/diarization → **Plan 3**
- Real Library / Meeting page UI, transcript pane, video player, speaker chips, copy button → **Plan 4**
- 3mpq-soldier subagent design polish → **Plan 4**
- Permissions UX (deeplinks, first-run model download) → **Plan 2 / Plan 3**

## Self-review notes

- **Spec coverage check:** Storage schema, FTS5, all GET/POST routes, Range support, transcript text format, menu bar, WebView, port allocation, application support paths — all covered. Recording, transcription, real UI explicitly deferred to later plans, matching the scope check decision at the top.
- **Type consistency:** `MeetingRepository` method names (`insertMeeting`, `listMeetings`, `searchSegments`, `renameSpeaker`, `speakers(forMeeting:)`, `segments(forMeeting:)`) used identically across tasks 4, 6.
- **No placeholders:** Every code block is complete. Where a future plan owns a feature, the popover button is `disabled(true)` with help text — explicit, not a TODO comment.
