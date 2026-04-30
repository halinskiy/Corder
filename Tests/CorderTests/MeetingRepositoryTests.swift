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
