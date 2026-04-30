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
