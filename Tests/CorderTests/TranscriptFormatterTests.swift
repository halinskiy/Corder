import XCTest
@testable import Corder

final class TranscriptFormatterTests: XCTestCase {
    func test_groups_consecutive_segments_by_speaker() {
        let speakers = [
            Speaker(id: "a", meetingId: "m", label: "Speaker 1", colorHex: "#000"),
            Speaker(id: "b", meetingId: "m", label: "Speaker 2", colorHex: "#111")
        ]
        let segs = [
            Segment(meetingId: "m", speakerId: "a", startMs: 0, endMs: 1_000, text: "Hi everyone"),
            Segment(meetingId: "m", speakerId: "a", startMs: 1_000, endMs: 2_000, text: "How are you"),
            Segment(meetingId: "m", speakerId: "b", startMs: 2_000, endMs: 3_000, text: "Let's start")
        ]
        // Same speaker → joined into one paragraph; different speaker → blank
        // line + new header.
        let out = TranscriptFormatter.clipboardText(segments: segs, speakers: speakers)
        XCTAssertEqual(out, """
        Speaker 1
        Hi everyone How are you

        Speaker 2
        Let's start
        """)
    }

    func test_renders_user_speaker_label_as_I() {
        // Pipeline tags the local user with `customName == "you"`. Clipboard
        // output should turn that into a natural "I" rather than echoing
        // the internal placeholder.
        let speakers = [
            Speaker(id: "a", meetingId: "m", label: "Speaker 1", customName: "you", colorHex: "#000")
        ]
        let segs = [Segment(meetingId: "m", speakerId: "a", startMs: 0, endMs: 1_000, text: "yo")]
        XCTAssertEqual(TranscriptFormatter.clipboardText(segments: segs, speakers: speakers),
                       "I\nyo")
    }

    func test_uses_custom_name_when_set() {
        let speakers = [
            Speaker(id: "a", meetingId: "m", label: "Speaker 1", customName: "Misha", colorHex: "#000")
        ]
        let segs = [Segment(meetingId: "m", speakerId: "a", startMs: 0, endMs: 1_000, text: "yo")]
        XCTAssertEqual(TranscriptFormatter.clipboardText(segments: segs, speakers: speakers),
                       "Misha\nyo")
    }

    func test_drops_empty_segments() {
        let speakers = [Speaker(id: "a", meetingId: "m", label: "Speaker 1", colorHex: "#000")]
        let segs = [
            Segment(meetingId: "m", speakerId: "a", startMs: 0, endMs: 1_000, text: "real"),
            Segment(meetingId: "m", speakerId: "a", startMs: 1_000, endMs: 2_000, text: "   "),
            Segment(meetingId: "m", speakerId: "a", startMs: 2_000, endMs: 3_000, text: "more")
        ]
        XCTAssertEqual(TranscriptFormatter.clipboardText(segments: segs, speakers: speakers),
                       "Speaker 1\nreal more")
    }

    func test_handles_unknown_speaker() {
        // Defensive: a segment whose speaker_id isn't in the speakers list
        // (shouldn't happen in production thanks to FK constraints, but the
        // formatter should never crash).
        let segs = [Segment(meetingId: "m", speakerId: "ghost", startMs: 0, endMs: 1_000, text: "huh")]
        XCTAssertEqual(TranscriptFormatter.clipboardText(segments: segs, speakers: []),
                       "Unknown\nhuh")
    }
}
