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
